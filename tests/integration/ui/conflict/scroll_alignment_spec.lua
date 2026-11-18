local h = require("tests.support")
local path = require("codediff.core.path")

--- Lines "line 001".."line NNN", with `replacements` swapping a line for a list of lines.
local function numbered_lines(count, replacements)
  local lines = {}
  for i = 1, count do
    vim.list_extend(lines, replacements[i] or { string.format("line %03d", i) })
  end
  return lines
end

local function topline(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview).topline
end

--- Zero-based screen row of the first line in `win` whose text is `text`, counting filler rows.
local function screen_row_of(win, text)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  local line = assert(vim.iter(ipairs(lines)):find(function(_, value)
    return value == text
  end))
  return vim.api.nvim_win_text_height(win, { start_row = 0, end_row = line - 1 }).all - 1
end

local function assert_row_aligned(session, text)
  local result_row = screen_row_of(session.result_win, text)
  assert.equals(screen_row_of(session.original_win, text), result_row, text .. " in Theirs and Result")
  assert.equals(screen_row_of(session.modified_win, text), result_row, text .. " in Ours and Result")
end

describe("conflict editor scroll alignment", function()
  local repo
  local saved_layout
  local saved_result_position

  before_each(function()
    h.ensure_plugin_loaded()
    local config = require("codediff.config")
    saved_layout = config.options.diff.layout
    saved_result_position = config.options.diff.conflict_result_position
    config.options.diff.layout = "side-by-side"
    config.options.diff.conflict_result_position = "bottom"

    repo = h.create_temp_git_repo()
    repo.write_file("file.txt", numbered_lines(80, {}))
    repo.git("add file.txt")
    repo.git("commit -m base")
    repo.git("checkout -b feature")
    repo.write_file("file.txt", numbered_lines(80, { [50] = { "feature 1", "feature 2", "feature 3" } }))
    repo.git("commit -am feature")
    repo.git("checkout main")
    repo.write_file("file.txt", numbered_lines(80, { [50] = { "main" } }))
    repo.git("commit -am main")
    local merge_output = repo.git("merge feature --no-edit")
    assert.is_true(merge_output:find("CONFLICT", 1, true) ~= nil, "merge must conflict")
  end)

  after_each(function()
    local config = require("codediff.config")
    config.options.diff.layout = saved_layout
    config.options.diff.conflict_result_position = saved_result_position
    require("codediff.ui.lifecycle").cleanup_all()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if repo then
      repo.cleanup()
    end
  end)

  local function open_conflict_editor()
    vim.cmd("edit " .. vim.fn.fnameescape(repo.path("file.txt")))

    local ready = false
    require("codediff.ui.view").create({
      git_root = repo.dir,
      original = path.make_ref("file.txt", repo.dir),
      modified = path.make_ref("file.txt", repo.dir),
      original_revision = ":3",
      modified_revision = ":2",
      conflict = true,
    }, nil, function()
      ready = true
    end)

    local lifecycle = require("codediff.ui.lifecycle")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local session
    assert.is_true(
      vim.wait(15000, function()
        session = lifecycle.get_session(tabpage)
        return ready and session and session.result_win and vim.api.nvim_win_is_valid(session.result_win)
      end, 50),
      "conflict editor never became ready"
    )
    return session
  end

  it("opens Result at the same row as the inputs scrolled to the first conflict", function()
    local session = open_conflict_editor()
    local scroll_sync = require("codediff.ui.view.scroll_sync")

    assert.is_true(topline(session.modified_win) > 1, "inputs must start scrolled to the first conflict")
    assert.equals(scroll_sync.top_row(session.modified_win), scroll_sync.top_row(session.result_win))
  end)

  it("keeps Result aligned after entering it and scrolling", function()
    local session = open_conflict_editor()
    local scroll_sync = require("codediff.ui.view.scroll_sync")

    vim.api.nvim_set_current_win(session.modified_win)
    vim.api.nvim_feedkeys(vim.keycode("<C-w>j"), "nx", false)
    assert.equals(session.result_win, vim.api.nvim_get_current_win())
    assert.equals(scroll_sync.top_row(session.modified_win), scroll_sync.top_row(session.result_win))

    local result_topline = topline(session.result_win)
    vim.api.nvim_feedkeys(vim.keycode("3<C-e>"), "nx", false)
    assert.equals(result_topline + 3, topline(session.result_win))
    assert.equals(scroll_sync.top_row(session.result_win), scroll_sync.top_row(session.modified_win))
    assert.equals(scroll_sync.top_row(session.result_win), scroll_sync.top_row(session.original_win))
  end)

  it("pads Result so the lines after a conflict share a screen row in every pane", function()
    local session = open_conflict_editor()

    assert_row_aligned(session, "line 049")
    assert_row_aligned(session, "line 051")
    assert_row_aligned(session, "line 080")
  end)

  it("pads the inputs when an edit makes Result taller than them", function()
    local session = open_conflict_editor()
    local result_lines = vim.api.nvim_buf_get_lines(session.result_bufnr, 0, -1, false)
    local conflict_line = assert(vim.iter(ipairs(result_lines)):find(function(_, value)
      return value == "line 050"
    end))

    vim.api.nvim_buf_set_lines(session.result_bufnr, conflict_line - 1, conflict_line, false, { "a", "b", "c", "d", "e", "f" })
    require("codediff.ui.conflict.view.result").render(session)

    assert_row_aligned(session, "line 051")
    assert_row_aligned(session, "line 080")
  end)
end)
