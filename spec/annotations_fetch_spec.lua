-- What an editor does with `annotations_available`: the daemon says which files have annotations, the editor
-- asks for the ones it has open, and the answer (a file's annotations plus its CoverageViews) is fed to the
-- same handlers the `file_annotations` and `coverage_view` frames use. Pure decisions, kept apart from the
-- SSE dispatcher (which does IO) so each can be tested on its own.
local fetch = require("sagefs.annotations_fetch")

describe("annotations_fetch", function()

  describe("files_to_fetch", function()
    it("asks for an available file that a buffer has open, by the daemon's own spelling", function()
      local wanted = fetch.files_to_fetch(
        { "/repo/src/A.fs", "/repo/src/B.fs", "/repo/src/C.fs" },
        { "/repo/src/B.fs" })
      assert.are.same({ "/repo/src/B.fs" }, wanted)
    end)

    it("matches a buffer path that is a suffix of the daemon's, or the other way round", function()
      local wanted = fetch.files_to_fetch(
        { "/daemon/root/src/A.fs", "src/B.fs" },
        { "src/A.fs", "/work/checkout/src/B.fs" })
      table.sort(wanted)
      assert.are.same({ "/daemon/root/src/A.fs", "src/B.fs" }, wanted)
    end)

    it("reads Windows separators and drive-case the way annotations.get_file does", function()
      local wanted = fetch.files_to_fetch({ "C:\\repo\\src\\A.fs" }, { "C:/repo/src/A.fs" })
      assert.are.same({ "C:\\repo\\src\\A.fs" }, wanted)
    end)

    it("asks for nothing when no open buffer is on the list", function()
      assert.are.same({}, fetch.files_to_fetch({ "/repo/A.fs" }, { "/elsewhere/Z.fs" }))
      assert.are.same({}, fetch.files_to_fetch({}, { "/repo/A.fs" }))
      assert.are.same({}, fetch.files_to_fetch({ "/repo/A.fs" }, {}))
    end)

    it("names each file once however many buffers match it", function()
      local wanted = fetch.files_to_fetch({ "/repo/A.fs" }, { "/repo/A.fs", "A.fs" })
      assert.are.same({ "/repo/A.fs" }, wanted)
    end)

    it("does not mistake a longer name that merely ends the same way", function()
      assert.are.same({}, fetch.files_to_fetch({ "/repo/FooA.fs" }, { "/repo/A.fs" }))
    end)

    it("does not choke on garbage", function()
      assert.are.same({}, fetch.files_to_fetch(nil, { "/a.fs" }))
      assert.are.same({}, fetch.files_to_fetch({ "/a.fs" }, nil))
      assert.are.same({}, fetch.files_to_fetch({ 1, false, "" }, { "/a.fs" }))
    end)
  end)

  describe("url", function()
    it("asks the session's file-annotations route for one file, escaped", function()
      assert.are.equal(
        "http://localhost:37749/api/live-testing/file-annotations?session=s1&file=%2Frepo%2Fsrc%2FA%20b.fs",
        fetch.url(37749, "s1", "/repo/src/A b.fs"))
    end)
  end)

  describe("split_answer", function()
    it("separates the annotations from the views, and does not change what it was given", function()
      local answer = {
        FilePath = "/repo/A.fs",
        TestAnnotations = { { Line = 3 } },
        CoverageViews = { { Symbol = "A.f", FilePath = "/repo/A.fs" }, { Symbol = "A.g", FilePath = "/repo/A.fs" } },
      }
      local annotations, views = fetch.split_answer(answer)
      assert.are.equal("/repo/A.fs", annotations.FilePath)
      assert.are.same({ { Line = 3 } }, annotations.TestAnnotations)
      assert.is_nil(annotations.CoverageViews, "the file_annotations handler gets the object a frame would carry")
      assert.are.equal(2, #views)
      assert.is_not_nil(answer.CoverageViews, "the caller's table is left alone")
    end)

    it("is no views for an answer without any", function()
      local _, views = fetch.split_answer({ FilePath = "/repo/A.fs" })
      assert.are.same({}, views)
    end)

    it("is nothing for something that is not an answer", function()
      local annotations, views = fetch.split_answer("garbage")
      assert.is_nil(annotations)
      assert.are.same({}, views)
    end)
  end)
end)
