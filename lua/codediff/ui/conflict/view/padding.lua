-- Pads the three conflict panes so they stay row-aligned under native scrollbind.
--
-- The two inputs are aligned with each other through BASE, but Result has its own
-- line structure (auto-merged content plus the user's edits). Lines left unchanged
-- from BASE in all three panes are anchors: between consecutive anchors every pane
-- is padded up to the tallest pane's row count, so each anchor sits on the same
-- screen row everywhere.
local M = {}

local api = vim.api
local filler = require("codediff.ui.filler")

local ns = api.nvim_create_namespace("codediff-conflict-padding")

--- Map each BASE line that `diff` leaves unchanged to its line in the diffed content.
local function unchanged_lines(diff, base_count)
  local lines, offset, base_line = {}, 0, 1
  for _, change in ipairs(diff.changes) do
    for line = base_line, change.original.start_line - 1 do
      lines[line] = line + offset
    end
    base_line = change.original.end_line
    offset = change.modified.end_line - change.original.end_line
  end
  for line = base_line, base_count do
    lines[line] = line + offset
  end
  return lines
end

local function is_anchor(maps, base_line)
  for _, map in ipairs(maps) do
    if not map[base_line] then
      return false
    end
  end
  return true
end

--- Whether two adjacent BASE lines are anchors with nothing inserted between them in any pane.
local function contiguous_anchors(maps, base_line, next_base_line)
  if not (is_anchor(maps, base_line) and is_anchor(maps, next_base_line)) then
    return false
  end
  for _, map in ipairs(maps) do
    if map[next_base_line] ~= map[base_line] + 1 then
      return false
    end
  end
  return true
end

--- Anchors that start or end a contiguous run; the regions between them hold every change.
local function anchor_boundaries(maps, base_count)
  local boundaries = {}
  for line = 1, base_count do
    if is_anchor(maps, line) and not (contiguous_anchors(maps, line - 1, line) and contiguous_anchors(maps, line, line + 1)) then
      boundaries[#boundaries + 1] = line
    end
  end
  return boundaries
end

--- Screen rows from the text of `from_line` to the text of `to_line`, where line 0 is the
--- top of the buffer and a nil `to_line` is its end.
local function rows_between(win, from_line, to_line)
  if not to_line then
    return api.nvim_win_text_height(win, { start_row = math.max(from_line - 1, 0) }).all
  end
  local rows = api.nvim_win_text_height(win, { start_row = from_line, end_row = to_line - 1 }).all
  return from_line == 0 and rows - 1 or rows
end

local function pad(pane, before_line, count)
  if count <= 0 then
    return
  end
  if before_line then
    filler.place(pane.buf, before_line - 1, count, { above = true, ns = ns })
  else
    filler.place(pane.buf, api.nvim_buf_line_count(pane.buf) - 1, count, { ns = ns })
  end
end

function M.clear(bufnrs)
  for _, bufnr in ipairs(bufnrs) do
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
end

--- Re-pad the panes. Each pane is `{ win, buf, diff }`, with `diff` from BASE to the pane's content.
function M.render(panes, base_count)
  M.clear(vim.tbl_map(function(pane)
    return pane.buf
  end, panes))
  for _, pane in ipairs(panes) do
    if not (api.nvim_win_is_valid(pane.win) and api.nvim_win_get_buf(pane.win) == pane.buf) then
      return
    end
  end

  local maps = {}
  for index, pane in ipairs(panes) do
    maps[index] = unchanged_lines(pane.diff, base_count)
  end

  local boundaries = anchor_boundaries(maps, base_count)
  local paddings = {}
  for segment = 0, #boundaries do
    local from_base, to_base = boundaries[segment], boundaries[segment + 1]
    local rows, tallest = {}, 0
    for index, pane in ipairs(panes) do
      local from_line = from_base and maps[index][from_base] or 0
      local to_line = to_base and maps[index][to_base]
      rows[index] = rows_between(pane.win, from_line, to_line)
      tallest = math.max(tallest, rows[index])
    end
    for index in ipairs(panes) do
      paddings[#paddings + 1] = { index = index, before_base = to_base, count = tallest - rows[index] }
    end
  end

  for _, padding in ipairs(paddings) do
    local before_line = padding.before_base and maps[padding.index][padding.before_base]
    pad(panes[padding.index], before_line, padding.count)
  end
end

return M
