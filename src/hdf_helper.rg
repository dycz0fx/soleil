-- Generate code for dumping/loading a subset of fields to/from an HDF file.
-- NOTE:
-- * Both functions require an intermediate region to perform the data
--   transfer. This region 's' must have the same size as 'r', and must be
--   partitioned in the same way.
-- * The dimensions will be flipped in the output file.
-- * You need to link to the HDF library to use these functions.

-------------------------------------------------------------------------------

import 'regent'

local Exports = {}

local C = regentlib.c
local HDF5 = terralib.includec(assert(os.getenv('HDF_HEADER')))
local UTIL = require 'util-desugared'

-- HACK: Hardcoding missing #define's
HDF5.H5F_ACC_TRUNC = 2
HDF5.H5P_DEFAULT = 0

-------------------------------------------------------------------------------

-- regentlib.index_type, regentlib.index_type, terralib.struct, string*
--   -> regentlib.task, regentlib.task
function Exports.mkHDFTasks(indexType, colorType, fSpace, flds)
  flds = terralib.newlist(flds)

  -- string, string? -> terralib.quote
  local function err(action, fld)
    if fld then
      return quote
        var stderr = C.fdopen(2, 'w')
        C.fprintf(stderr, 'HDF5: Cannot %s for field %s\n', action, fld)
        C.fflush(stderr)
        C.exit(1)
      end
    else
      return quote
        var stderr = C.fdopen(2, 'w')
        C.fprintf(stderr, 'HDF5: Cannot %s\n', action)
        C.fflush(stderr)
        C.exit(1)
      end
    end
  end

  local terra create(fname : &int8, size : indexType)
    var fid = HDF5.H5Fcreate(fname, HDF5.H5F_ACC_TRUNC,
                             HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT)
    if fid < 0 then [err('create file')] end
    var dataSpace : HDF5.hid_t
    escape
      if indexType == int1d then
        emit quote
          var sizes : HDF5.hsize_t[1]
          sizes[0] = size.__ptr
          dataSpace = HDF5.H5Screate_simple(1, sizes, [&uint64](0))
          if dataSpace < 0 then [err('create 1d dataspace')] end
        end
      elseif indexType == int2d then
        emit quote
          -- Legion defaults to column-major layout, so we have to reverse.
          var sizes : HDF5.hsize_t[2]
          sizes[1] = size.__ptr.x
          sizes[0] = size.__ptr.y
          dataSpace = HDF5.H5Screate_simple(2, sizes, [&uint64](0))
          if dataSpace < 0 then [err('create 2d dataspace')] end
        end
      elseif indexType == int3d then
        emit quote
          -- Legion defaults to column-major layout, so we have to reverse.
          var sizes : HDF5.hsize_t[3]
          sizes[2] = size.__ptr.x
          sizes[1] = size.__ptr.y
          sizes[0] = size.__ptr.z
          dataSpace = HDF5.H5Screate_simple(3, sizes, [&uint64](0))
          if dataSpace < 0 then [err('create 3d dataspace')] end
        end
      else assert(false) end
      local header = terralib.newlist() -- terralib.quote*
      local footer = terralib.newlist() -- terralib.quote*
      -- terralib.type -> terralib.quote
      local function toHType(T)
        -- TODO: Not supporting: pointers, vectors, non-primitive arrays
        if T:isprimitive() then
          return
            -- HACK: Hardcoding missing #define's
            (T == int)    and HDF5.H5T_STD_I32LE_g  or
            (T == int8)   and HDF5.H5T_STD_I8LE_g   or
            (T == int16)  and HDF5.H5T_STD_I16LE_g  or
            (T == int32)  and HDF5.H5T_STD_I32LE_g  or
            (T == int64)  and HDF5.H5T_STD_I64LE_g  or
            (T == uint)   and HDF5.H5T_STD_U32LE_g  or
            (T == uint8)  and HDF5.H5T_STD_U8LE_g   or
            (T == uint16) and HDF5.H5T_STD_U16LE_g  or
            (T == uint32) and HDF5.H5T_STD_U32LE_g  or
            (T == uint64) and HDF5.H5T_STD_U64LE_g  or
            (T == bool)   and HDF5.H5T_STD_U8LE_g   or
            (T == float)  and HDF5.H5T_IEEE_F32LE_g or
            (T == double) and HDF5.H5T_IEEE_F64LE_g or
            assert(false)
        elseif T:isarray() then
          local elemType = toHType(T.type)
          local arrayType = symbol(HDF5.hid_t, 'arrayType')
          header:insert(quote
            var dims : HDF5.hsize_t[1]
            dims[0] = T.N
            var elemType = [elemType]
            var [arrayType] = HDF5.H5Tarray_create2(elemType, 1, dims)
            if arrayType < 0 then [err('create array type')] end
          end)
          footer:insert(quote
            HDF5.H5Tclose(arrayType)
          end)
          return arrayType
        else assert(false) end
      end
      -- terralib.struct, set(string), string -> ()
      local function emitFieldDecls(fs, whitelist, prefix)
        -- TODO: Only supporting pure structs, not fspaces
        assert(fs:isstruct())
        for _,e in ipairs(fs.entries) do
          local name, type = UTIL.parseStructEntry(e)
          if whitelist and not whitelist[name] then
            -- do nothing
          elseif type == int2d then
            -- Hardcode special case: int2d structs are stored packed
            local hName = prefix..name
            local int2dType = symbol(HDF5.hid_t, 'int2dType')
            local dataSet = symbol(HDF5.hid_t, 'dataSet')
            header:insert(quote
              var [int2dType] = HDF5.H5Tcreate(HDF5.H5T_COMPOUND, 16)
              if int2dType < 0 then [err('create 2d array type', name)] end
              var x = HDF5.H5Tinsert(int2dType, "x", 0, HDF5.H5T_STD_I64LE_g)
              if x < 0 then [err('add x to 2d array type', name)] end
              var y = HDF5.H5Tinsert(int2dType, "y", 8, HDF5.H5T_STD_I64LE_g)
              if y < 0 then [err('add y to 2d array type', name)] end
              var [dataSet] = HDF5.H5Dcreate2(
                fid, hName, int2dType, dataSpace,
                HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT)
              if dataSet < 0 then [err('register 2d array type', name)] end
            end)
            footer:insert(quote
              HDF5.H5Dclose(dataSet)
              HDF5.H5Tclose(int2dType)
            end)
          elseif type == int3d then
            -- Hardcode special case: int3d structs are stored packed
            local hName = prefix..name
            local int3dType = symbol(HDF5.hid_t, 'int3dType')
            local dataSet = symbol(HDF5.hid_t, 'dataSet')
            header:insert(quote
              var [int3dType] = HDF5.H5Tcreate(HDF5.H5T_COMPOUND, 24)
              if int3dType < 0 then [err('create 3d array type', name)] end
              var x = HDF5.H5Tinsert(int3dType, "x", 0, HDF5.H5T_STD_I64LE_g)
              if x < 0 then [err('add x to 3d array type', name)] end
              var y = HDF5.H5Tinsert(int3dType, "y", 8, HDF5.H5T_STD_I64LE_g)
              if y < 0 then [err('add y to 3d array type', name)] end
              var z = HDF5.H5Tinsert(int3dType, "z", 16, HDF5.H5T_STD_I64LE_g)
              if z < 0 then [err('add z to 3d array type', name)] end
              var [dataSet] = HDF5.H5Dcreate2(
                fid, hName, int3dType, dataSpace,
                HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT)
              if dataSet < 0 then [err('register 3d array type', name)] end
            end)
            footer:insert(quote
              HDF5.H5Dclose(dataSet)
              HDF5.H5Tclose(int3dType)
            end)
          elseif type:isstruct() then
            emitFieldDecls(type, nil, prefix..name..'.')
          else
            local hName = prefix..name
            local hType = toHType(type)
            local dataSet = symbol(HDF5.hid_t, 'dataSet')
            header:insert(quote
              var hType = [hType]
              var [dataSet] = HDF5.H5Dcreate2(
                fid, hName, hType, dataSpace,
                HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT, HDF5.H5P_DEFAULT)
              if dataSet < 0 then [err('register type', name)] end
            end)
            footer:insert(quote
              HDF5.H5Dclose(dataSet)
            end)
          end
        end
      end
      emitFieldDecls(fSpace, flds:toSet(), '')
      emit quote [header] end
      emit quote [footer:reverse()] end
    end
    HDF5.H5Sclose(dataSpace)
    HDF5.H5Fclose(fid)
  end

  local tileFilename
  if indexType == int1d then
    __demand(__inline) task tileFilename(dirname : &int8, bounds : rect1d)
      var filename = [&int8](C.malloc(256))
      var lo = bounds.lo
      var hi = bounds.hi
      C.snprintf(filename, 256,
                 '%s/%ld-%ld.hdf', dirname,
                 lo, hi)
      return filename
    end
  elseif indexType == int2d then
    __demand(__inline) task tileFilename(dirname : &int8, bounds : rect2d)
      var filename = [&int8](C.malloc(256))
      var lo = bounds.lo
      var hi = bounds.hi
      C.snprintf(filename, 256,
                 '%s/%ld,%ld-%ld,%ld.hdf', dirname,
                 lo.x, lo.y, hi.x, hi.y)
      return filename
    end
  elseif indexType == int3d then
    __demand(__inline) task tileFilename(dirname : &int8, bounds : rect3d)
      var filename = [&int8](C.malloc(256))
      var lo = bounds.lo
      var hi = bounds.hi
      C.snprintf(filename, 256,
                 '%s/%ld,%ld,%ld-%ld,%ld,%ld.hdf', dirname,
                 lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
      return filename
    end
  else assert(false) end

  local one =
    indexType == int1d and rexpr 1 end or
    indexType == int2d and rexpr {1,1} end or
    indexType == int3d and rexpr {1,1,1} end or
    assert(false)

  local -- NOT LEAF, MANUALLY PARALLELIZED, NO CUDA, NO OPENMP
  task dumpTile(_ : int,
                dirname : regentlib.string,
                r : region(ispace(indexType),fSpace),
                s : region(ispace(indexType),fSpace))
  where reads(r.[flds]), reads writes(s.[flds]), r * s do
    var filename = tileFilename([&int8](dirname), r.bounds)
    create(filename, r.bounds.hi - r.bounds.lo + one)
    attach(hdf5, s.[flds], filename, regentlib.file_read_write)
    acquire(s.[flds])
    copy(r.[flds], s.[flds])
    release(s.[flds])
    detach(hdf5, s.[flds])
    C.free(filename)
    return _
  end

  local __demand(__inline)
  task dump(_ : int,
            colors : ispace(colorType),
            dirname : &int8,
            r : region(ispace(indexType),fSpace),
            s : region(ispace(indexType),fSpace),
            p_r : partition(disjoint, r, colors),
            p_s : partition(disjoint, s, colors))
  where reads(r.[flds]), reads writes(s.[flds]), r * s do
    -- TODO: Sanity checks: bounds.lo == 0, same size, compatible partitions
    var __ = 0
    for c in colors do
      __ += dumpTile(_, [regentlib.string](dirname), p_r[c], p_s[c])
    end
    return __
  end

  local -- NOT LEAF, MANUALLY PARALLELIZED, NO CUDA, NO OPENMP
  task loadTile(_ : int,
                dirname : regentlib.string,
                r : region(ispace(indexType),fSpace),
                s : region(ispace(indexType),fSpace))
  where reads writes(r.[flds]), reads writes(s.[flds]), r * s do
    var filename = tileFilename([&int8](dirname), r.bounds)
    attach(hdf5, s.[flds], filename, regentlib.file_read_only)
    acquire(s.[flds])
    copy(s.[flds], r.[flds])
    release(s.[flds])
    detach(hdf5, s.[flds])
    C.free(filename)
    return _
  end

  local __demand(__inline)
  task load(_ : int,
            colors : ispace(colorType),
            dirname : &int8,
            r : region(ispace(indexType),fSpace),
            s : region(ispace(indexType),fSpace),
            p_r : partition(disjoint, r, colors),
            p_s : partition(disjoint, s, colors))
  where reads writes(r.[flds]), reads writes(s.[flds]), r * s do
    -- TODO: Sanity checks: bounds.lo == 0, same size, compatible partitions
    -- TODO: Check that the file has the correct size etc.
    var __ = 0
    for c in colors do
      __ += loadTile(_, [regentlib.string](dirname), p_r[c], p_s[c])
    end
    return __
  end

  return dump, load
end

-------------------------------------------------------------------------------

return Exports
