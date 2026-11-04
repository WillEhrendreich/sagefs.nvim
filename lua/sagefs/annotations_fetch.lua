-- What an editor does with `annotations_available`.
--
-- On connect the daemon used to send one `file_annotations` frame and one `coverage_view` frame per function
-- for EVERY file of the session, because nothing told it which files an editor had open. It now says which
-- files have annotations (`annotations_available`) and the editor asks for the ones it has open:
-- GET /api/live-testing/file-annotations?session=<id>&file=<path> answers a file's annotations with its
-- `CoverageViews`, each exactly the data of a `coverage_view` frame. Which files to ask for, where to ask,
-- and how to hand the answer to the frame handlers are pure questions; the SSE dispatcher (IO) and the
-- reducers (state, data -> state) should not have to answer them.
local M = {}

local function normalize(path)
  return (path:gsub("\\", "/"))
end

--- Is `short` the tail of `long` on a path boundary? (`/repo/A.fs` ends `A.fs`; `/repo/FooA.fs` does not.)
local function ends_with_path(long, short)
  if long == short then return true end
  if #short > #long then return false end
  if long:sub(-#short) ~= short then return false end
  return short:sub(1, 1) == "/" or long:sub(-#short - 1, -#short - 1) == "/"
end

local function same_file(a, b)
  return ends_with_path(a, b) or ends_with_path(b, a)
end

--- The daemon's spellings of the available files that some open buffer is.
---@param available string[]|nil the files `annotations_available` listed
---@param open_paths string[]|nil the paths of the buffers that are open
---@return string[]
function M.files_to_fetch(available, open_paths)
  local wanted = {}
  if type(available) ~= "table" or type(open_paths) ~= "table" then return wanted end
  local normalized_open = {}
  for _, path in ipairs(open_paths) do
    if type(path) == "string" and path ~= "" then
      normalized_open[#normalized_open + 1] = normalize(path)
    end
  end
  for _, file in ipairs(available) do
    if type(file) == "string" and file ~= "" then
      local daemon_path = normalize(file)
      for _, open in ipairs(normalized_open) do
        if same_file(daemon_path, open) then
          wanted[#wanted + 1] = file
          break
        end
      end
    end
  end
  return wanted
end

local function escape(text)
  return (text:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- Where to ask for one file of one session.
---@param port integer
---@param session_id string
---@param file string
---@return string
function M.url(port, session_id, file)
  return string.format(
    "http://localhost:%d/api/live-testing/file-annotations?session=%s&file=%s",
    port, escape(session_id), escape(file))
end

--- Split an answer into what a `file_annotations` frame carries and the views of `coverage_view` frames.
--- The caller's table is not changed.
---@param answer table|any
---@return table|nil annotations, table[] views
function M.split_answer(answer)
  if type(answer) ~= "table" then return nil, {} end
  local annotations = {}
  for key, value in pairs(answer) do
    if key ~= "CoverageViews" then annotations[key] = value end
  end
  local views = answer.CoverageViews
  if type(views) ~= "table" then views = {} end
  return annotations, views
end

return M
