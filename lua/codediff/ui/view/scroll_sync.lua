-- Keeps scrollbound diff panes aligned across filler blocks taller than the window.
--
-- Native scrollbind moves the other pane by virtual rows, but Neovim cannot show a
-- window made only of virtual lines: `check_topfill` caps 'topfill' below the
-- window height. Inside an oversized filler block the native sync therefore
-- alternates between two unrelated views on every scrolled line. After each
-- scroll, this module puts the other pane on the nearest view it can display.
local api = vim.api

local M = {}

local function rows_through(win, line)
  if line < 1 then
    return 0
  end
  return api.nvim_win_text_height(win, { start_row = 0, end_row = line - 1 }).all
end

--- Virtual lines Neovim shows above `line`, including those placed below the previous line.
local function filler_above(win, line)
  return api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 }).fill
end

local function text_row(win, line)
  return rows_through(win, line - 1) + filler_above(win, line)
end

--- Zero-based index of the window's first screen row within the whole buffer rendering.
function M.top_row(win)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  return text_row(win, view.topline) - view.topfill
end

--- The displayable view whose first screen row is closest to `row`.
function M.view_for_row(win, row)
  local low, high = 1, api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  while low < high do
    local mid = math.floor((low + high) / 2)
    if text_row(win, mid) >= row then
      high = mid
    else
      low = mid + 1
    end
  end

  local topfill = text_row(win, low) - row
  if topfill < 0 then
    return { topline = low, topfill = 0 }
  end
  if topfill > filler_above(win, low) then
    return { topline = math.max(low - 1, 1), topfill = 0 }
  end
  return { topline = low, topfill = math.min(topfill, vim.fn.winheight(win) - 1) }
end

local function bound_panes(sess)
  if not sess or sess.layout ~= "side-by-side" or (sess.result_win and api.nvim_win_is_valid(sess.result_win)) then
    return nil
  end
  local original_win, modified_win = sess.original_win, sess.modified_win
  if not (original_win and modified_win and api.nvim_win_is_valid(original_win) and api.nvim_win_is_valid(modified_win)) then
    return nil
  end
  if not (vim.wo[original_win].scrollbind and vim.wo[modified_win].scrollbind) then
    return nil
  end
  return original_win, modified_win
end

local function scrolled_source(original_win, modified_win)
  local current = api.nvim_get_current_win()
  if current == original_win or current == modified_win then
    return current
  end
  local scrolled = vim.v.event or {}
  local original_scrolled = scrolled[tostring(original_win)] ~= nil
  local modified_scrolled = scrolled[tostring(modified_win)] ~= nil
  if original_scrolled ~= modified_scrolled then
    return original_scrolled and original_win or modified_win
  end
end

--- Re-anchor 'scrollbind' at the window's current view. A view changed by anything other than
--- a bound scroll (winrestview, a resize) leaves a stale anchor, and the 'jump' flag of
--- 'scrollopt' then scrolls the other panes by the difference when the window is entered.
function M.reset_scrollbind_anchor(win)
  api.nvim_win_call(win, function()
    if vim.wo.scrollbind then
      vim.wo.scrollbind = false
      vim.wo.scrollbind = true
    end
  end)
end

--- Scroll `target` so its first screen row lines up with the first screen row of `source`.
function M.align(source, target)
  local view = M.view_for_row(target, M.top_row(source))
  local current = api.nvim_win_call(target, vim.fn.winsaveview)
  if current.topline ~= view.topline or current.topfill ~= view.topfill then
    api.nvim_win_call(target, function()
      vim.fn.winrestview(view)
    end)
    M.reset_scrollbind_anchor(target)
  end
end

--- First and last rows of `win` the cursor can sit on without scrolling, given 'scrolloff'.
local function cursor_safe_rows(win)
  local top = M.top_row(win)
  local height = vim.fn.winheight(win)
  local margin = math.min(vim.wo[win].scrolloff, math.floor((height - 1) / 2))
  return top + margin, top + height - 1 - margin
end

--- The line nearest `row` whose text sits on a row the cursor can use without scrolling.
--- A row inside filler belongs to no line, so prefer the line above the filler when the
--- line below it is out of reach.
local function cursor_line_near_row(win, row)
  local first, last = cursor_safe_rows(win)
  row = math.max(first, math.min(row, last))
  local line = M.view_for_row(win, row).topline
  if text_row(win, line) > last and line > 1 and text_row(win, line - 1) >= first then
    return line - 1
  end
  return line
end

--- Align `target` with `source` and put its cursor as close as it can to the row of the source
--- cursor while staying in view, so entering `target` does not scroll it to its old cursor.
function M.align_with_cursor(source, target)
  M.align(source, target)
  local source_cursor_row = text_row(source, api.nvim_win_get_cursor(source)[1])
  api.nvim_win_set_cursor(target, { cursor_line_near_row(target, source_cursor_row), 0 })
end

--- Correct the opposite pane after every scroll in a side-by-side session.
function M.attach(tabpage, augroup, get_session)
  api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if api.nvim_get_current_tabpage() ~= tabpage then
        return
      end
      local original_win, modified_win = bound_panes(get_session(tabpage))
      if not original_win then
        return
      end
      local source = scrolled_source(original_win, modified_win)
      if source then
        M.align(source, source == original_win and modified_win or original_win)
      end
    end,
  })
end

return M
