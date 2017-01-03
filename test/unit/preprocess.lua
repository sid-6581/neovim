-- helps managing loading different headers into the LuaJIT ffi. Untested on
-- windows, will probably need quite a bit of adjustment to run there.

local global_helpers = require('test.helpers')

local ffi = require("ffi")

local tmpname = global_helpers.tmpname

local ccs = {}

local env_cc = os.getenv("CC")
if env_cc then
  table.insert(ccs, {path = "/usr/bin/env " .. tostring(env_cc), type = "gcc"})
end

if ffi.os == "Windows" then
  table.insert(ccs, {path = "cl", type = "msvc"})
end

table.insert(ccs, {path = "/usr/bin/env cc", type = "gcc"})
table.insert(ccs, {path = "/usr/bin/env gcc", type = "gcc"})
table.insert(ccs, {path = "/usr/bin/env gcc-4.9", type = "gcc"})
table.insert(ccs, {path = "/usr/bin/env gcc-4.8", type = "gcc"})
table.insert(ccs, {path = "/usr/bin/env gcc-4.7", type = "gcc"})
table.insert(ccs, {path = "/usr/bin/env clang", type = "clang"})
table.insert(ccs, {path = "/usr/bin/env icc", type = "gcc"})

local quote_me = '[^%w%+%-%=%@%_%/]' -- complement (needn't quote)
local function shell_quote(str)
  if string.find(str, quote_me) or str == '' then
    return "'" .. string.gsub(str, "'", [['"'"']]) .. "'"
  else
    return str
  end
end

-- parse Makefile format dependencies into a Lua table
local function parse_make_deps(deps)
  -- remove line breaks and line concatenators
  deps = deps:gsub("\n", ""):gsub("\\", "")
  -- remove the Makefile "target:" element
  deps = deps:gsub(".+:", "")
  -- remove redundant spaces
  deps = deps:gsub("  +", " ")

  -- split according to token (space in this case)
  local headers = {}
  for token in deps:gmatch("[^%s]+") do
    -- headers[token] = true
    headers[#headers + 1] = token
  end

  -- resolve path redirections (..) to normalize all paths
  for i, v in ipairs(headers) do
    -- double dots (..)
    headers[i] = v:gsub("/[^/%s]+/%.%.", "")
    -- single dot (.)
    headers[i] = v:gsub("%./", "")
  end

  return headers
end

-- will produce a string that represents a meta C header file that includes
-- all the passed in headers. I.e.:
--
-- headerize({"stdio.h", "math.h"}, true)
-- produces:
-- #include <stdio.h>
-- #include <math.h>
--
-- headerize({"vim.h", "memory.h"}, false)
-- produces:
-- #include "vim.h"
-- #include "memory.h"
local function headerize(headers, global)
  local pre = '"'
  local post = pre
  if global then
    pre = "<"
    post = ">"
  end

  local formatted = {}
  for i, hdr in ipairs(headers) do
    formatted[#formatted + 1] = "#include " ..
                                tostring(pre) ..
                                tostring(hdr) ..
                                tostring(post)
  end

  return table.concat(formatted, "\n")
end

local Gcc = {
  -- preprocessor flags that will hopefully make the compiler produce C
  -- declarations that the LuaJIT ffi understands.
  preprocessor_extra_flags = {
   '-D "aligned(ARGS)="',
   '-D "__attribute__(ARGS)="',
   '-D "__asm(ARGS)="',
   '-D "__asm__(ARGS)="',
   '-D "__inline__="',
   '-D "EXTERN=extern"',
   '-D "INIT(...)="',
   '-D_GNU_SOURCE',
   '-DINCLUDE_GENERATED_DECLARATIONS',

   -- Needed for FreeBSD
   '-D "_Thread_local="',

   -- Needed for macOS Sierra
   '-D "_Nullable="',
   '-D "_Nonnull="',
   '-U__BLOCKS__',
  },
}

function Gcc:new(obj)
  obj = obj or {}
  setmetatable(obj, self)
  self.__index = self
  return obj
end

function Gcc:add_to_include_path(...)
  local paths = {...}
  for i = 1, #paths do
    local path = paths[i]
    local directive = '-I ' .. '"' .. path .. '"'
    local ef = self.preprocessor_extra_flags
    ef[#ef + 1] = directive
  end
end

-- returns a list of the headers files upon which this file relies
function Gcc:dependencies(hdr)
  local out = io.popen(tostring(self.path) .. " -M " .. tostring(hdr) .. " 2>&1")
  local deps = out:read("*a")
  out:close()
  if deps then
    return parse_make_deps(deps)
  else
    return nil
  end
end

local function repeated_call(cmd)
  for _ = 1, 10 do
    local stream = io.popen(cmd)
    local ret = stream:read('*a')
    stream:close()
    if ret then
      return ret
    end
  end
  print('ERROR: preprocess.lua: Failed to execute ' .. cmd .. ': nil return after 10 attempts')
  return nil
end

-- returns a stream representing a preprocessed form of the passed-in headers.
-- Don't forget to close the stream by calling the close() method on it.
function Gcc:preprocess(previous_defines, ...)
  -- create pseudo-header
  local pseudoheader = headerize({...}, false)
  local pseudoheader_fname = 'tmp_pseudoheader.h'
  local pseudoheader_file = io.open(pseudoheader_fname, 'w')
  pseudoheader_file:write(previous_defines)
  pseudoheader_file:write("\n")
  pseudoheader_file:write(pseudoheader)
  pseudoheader_file:flush()
  pseudoheader_file:close()
  local defines = table.concat(self.preprocessor_extra_flags, ' ')
  local cmd_base = self.path .. " " .. defines .. " -std=c99"

  local def_cmd = (cmd_base .. " -dM -E " .. shell_quote(pseudoheader_fname))
  local defines = repeated_call(def_cmd)

  -- lfs = require("lfs")
  -- print("CWD: #{lfs.currentdir!}")
  -- print("CMD: #{cmd}")
  -- io.stderr\write("CWD: #{lfs.currentdir!}\n")
  -- io.stderr\write("CMD: #{cmd}\n")
  local decl_cmd = (cmd_base .. " -P -E " .. shell_quote(pseudoheader_fname))
  local declarations = repeated_call(decl_cmd)

  os.remove(pseudoheader_fname)

  assert(declarations and defines)
  return declarations, defines
end

local Clang = Gcc:new()
local Msvc = Gcc:new()

local type_to_class = {
  ["gcc"] = Gcc,
  ["clang"] = Clang,
  ["msvc"] = Msvc
}

-- find the best cc. If os.exec causes problems on windows (like popping up
-- a console window) we might consider using something like this:
-- http://scite-ru.googlecode.com/svn/trunk/pack/tools/LuaLib/shell.html#exec
local function find_best_cc(compilers)
  for _, meta in pairs(compilers) do
    local version = io.popen(tostring(meta.path) .. " -v 2>&1")
    version:close()
    if version then
      return type_to_class[meta.type]:new({path = meta.path})
    end
  end
  return nil
end

-- find the best cc. If os.exec causes problems on windows (like popping up
-- a console window) we might consider using something like this:
-- http://scite-ru.googlecode.com/svn/trunk/pack/tools/LuaLib/shell.html#exec
local cc = nil
if cc == nil then
  cc = find_best_cc(ccs)
end

return {
  includes = function(hdr)
    return cc:dependencies(hdr)
  end,
  preprocess = function(...)
    return cc:preprocess(...)
  end,
  add_to_include_path = function(...)
    return cc:add_to_include_path(...)
  end
}
