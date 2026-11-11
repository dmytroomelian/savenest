import AppKit
import SaveNestCore

/// Page metadata first; article extraction only after the user chooses Reader.
@MainActor
enum ReaderCapture {
    static func current(using capture: BrowserCapture, sourceApplication: NSRunningApplication? = nil, preview: Bool = false) async throws -> [String: Any] {
        if preview { return fixture() }
        let browser = try capture.target(sourceApplication: sourceApplication)
        let result = try await read(browser: browser, target: nil, extractArticle: false)
        guard let url = result["url"] as? String, Library.validatedURL(url) != nil else {
            throw CaptureError.noTabs
        }
        return result
    }

    static func selected(_ item: TabWorkspaceItem, preview: Bool = false) async -> [String: Any] {
        if preview { return fixture(url: item.url, title: item.title, quickNote: item.link?.note ?? "") }
        var source: [String: Any] = ["url": item.url, "title": item.title, "quickNote": item.link?.note ?? ""]
        if let tab = item.tab {
            source["readerTarget"] = ["browserID": tab.browserID, "windowID": tab.windowID, "tabID": tab.tabID, "index": tab.index, "url": tab.url]
        }
        return source
    }

    static func extract(_ source: [String: Any], preview: Bool = false) async -> [String: Any] {
        if preview { return fixture(url: source["url"] as? String ?? "", title: source["title"] as? String ?? "Untitled page") }
        var source = source
        guard let target = source["readerTarget"] as? [String: Any],
              let browserID = target["browserID"] as? String,
              let browser = Browser.supported.first(where: { $0.id == browserID }) else {
            source["captureError"] = "Open this page in a supported browser, then reopen Read & note to use Reader."
            return source
        }
        do {
            let captured = try await read(browser: browser, target: target, extractArticle: true)
            // Keep the requested page identity even when the browser changed during extraction.
            guard captured["url"] as? String == source["url"] as? String else {
                source["captureError"] = "The browser tab changed. Reopen Read & note from the page you want."
                return source
            }
            source.merge(captured) { _, new in new }
        } catch {
            source["captureError"] = "Couldn’t read this browser tab. Check browser Automation access, or load the original page."
        }
        return source
    }

    private static func read(browser: Browser, target: [String: Any]?, extractArticle: Bool) async throws -> [String: Any] {
        let page = extractArticle ? pageScript() : ""
        let payload = try JSONSerialization.data(withJSONObject: ["browserID": browser.id, "safari": browser.safari, "target": target as Any? ?? NSNull(), "source": page])
        let script = ReaderCaptureScript.browser + "\nfunction run() { const p = " + String(decoding: payload, as: UTF8.self) + "; return JSON.stringify(readReaderTab(Application(p.browserID), p.safari, p.target, p.source)); }"
        let bytes = try await BrowserScript.run(script, timeout: 12)
        guard bytes.count <= 500_000,
              var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CaptureError.failed("This article is too large for Reader. Load the original page instead.")
        }
        if var readerTarget = result["readerTarget"] as? [String: Any] {
            readerTarget["browserID"] = browser.id
            result["readerTarget"] = readerTarget
        }
        if let article = result["article"] as? [String: Any] {
            // Renderer must sanitize this HTML independently. No captured markup is trusted UI.
            guard let content = article["content"] as? String, content.utf8.count <= 350_000,
                  let title = article["title"] as? String, title.count <= 10_000,
                  let text = article["textContent"] as? String, text.count <= 100_000 else {
                result.removeValue(forKey: "article")
                result["captureError"] = "This article is too large for Reader. Load the original page instead."
                return result
            }
        }
        return result
    }

    private static func pageScript() -> String {
        guard let resource = Bundle.main.url(forResource: "ReaderReadability", withExtension: "js"),
              let library = try? String(contentsOf: resource, encoding: .utf8) else {
            return "JSON.stringify({url:location.href,error:'Reader is unavailable in this build. Load the original page instead.'})"
        }
        // Shadow CommonJS globals so the bundled library cannot alter a website's module object.
        return "(() => { const module = {exports:{}}; const exports = module.exports;\n" + library + "\n" + ReaderCaptureScript.page + "\n})()"
    }

    static func fixture(url: String = "https://example.com/a-place-for-your-thoughts", title: String = "A place for your thoughts", quickNote: String = "") -> [String: Any] {
        let paragraphs = [
            "A good reading space does two things well: it brings the source close, and gives your own thinking room to grow. The most useful note is often a question, a connection, or a sentence you want to revisit.",
            "Keep the article on one side and your words on the other. Read a paragraph. Pause. Write what it means to you. The act of putting an idea into your own words makes it easier to find again.",
            "Your notes are ordinary Markdown files in an Obsidian vault. They stay yours, open in the tools you already use, and return when you revisit the same page.",
            "This preview uses a sample article and a disposable vault. Try a heading, a short list, or a few thoughts. Close the window and come back to see your note again."
        ]
        let firstSection = paragraphs.prefix(2).map { "<p>\($0)</p>" }.joined()
        let secondSection = paragraphs.suffix(2).map { "<p>\($0)</p>" }.joined()
        let content = [
            "<article><p class=\"reader-lede\">A quiet space between reading and understanding.</p><h2>Read, then make it yours</h2>",
            firstSection,
            "<blockquote>The value is in the thought you add.</blockquote><h2>Keep your words close</h2>",
            secondSection,
            "<ul><li>Write a question you want to explore.</li><li>Connect this page to something you already know.</li><li>Leave one useful sentence for your future self.</li></ul></article>"
        ].joined()
        let article: [String: Any] = [
            "title": title,
            "byline": "Savenest sample article",
            "content": content,
            "textContent": paragraphs.joined(separator: "\n\n")
        ]
        return ["url": url, "title": title, "quickNote": quickNote, "article": article]
    }
}

enum ReaderCaptureScript {
    // Runs inside the explicitly selected tab. Readability receives an inert clone, never the live DOM.
    static let page = #"""
    const originalURL = location.href;
    try {
      const excluded = 'script,style,noscript,template,iframe,object,embed,form,input,textarea,select,button,[contenteditable]:not([contenteditable="false"]),[hidden],[aria-hidden="true"],[inert]';
      const live = Array.from(document.querySelectorAll('*'));
      if (live.length > 30000) return JSON.stringify({url:originalURL,error:'This page is too large for Reader. Load the original page instead.'});
      const clone = document.cloneNode(true);
      const copies = Array.from(clone.querySelectorAll('*'));
      // Also remove content hidden by site styles, which are absent from the detached clone.
      for (let i = live.length - 1; i >= 0; i--) {
        const node = live[i], copy = copies[i];
        if (!copy) continue;
        if (node.matches(excluded)) { copy.remove(); continue; }
        if (node === document.documentElement || node === document.head || node === document.body || document.head.contains(node)) continue;
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.contentVisibility === 'hidden' || style.opacity === '0') copy.remove();
      }
      clone.querySelectorAll(excluded).forEach(node => node.remove());
      // Resolve only safe resource references. The renderer suppresses image requests until requested.
      clone.querySelectorAll('[href],[src],[srcset]').forEach(node => {
        node.removeAttribute('srcset');
        for (const attribute of ['href','src']) {
          if (!node.hasAttribute(attribute)) continue;
          try {
            const url = new URL(node.getAttribute(attribute), document.baseURI);
            if (!['http:','https:'].includes(url.protocol) || url.username || url.password) node.removeAttribute(attribute);
            else node.setAttribute(attribute,url.href);
          } catch (_) { node.removeAttribute(attribute); }
        }
        for (const attribute of Array.from(node.attributes)) {
          if (/^on/i.test(attribute.name)) node.removeAttribute(attribute.name);
        }
      });
      const article = new Readability(clone, {maxElemsToParse:30000}).parse();
      if (location.href !== originalURL) return JSON.stringify({url:originalURL,error:'The browser tab changed. Reopen Read & note from the page you want.'});
      if (!article || !article.content || !article.textContent || article.textContent.trim().length < 80) return JSON.stringify({url:originalURL,error:'Reader could not find an article on this page. Load the original page instead.'});
      const value = {url:originalURL,article:{title:String(article.title||document.title).slice(0,10000),byline:String(article.byline||'').slice(0,1000),content:article.content,textContent:article.textContent}};
      const json = JSON.stringify(value);
      if (article.textContent.length > 100000 || new TextEncoder().encode(article.content).length > 350000 || new TextEncoder().encode(json).length > 400000) return JSON.stringify({url:originalURL,error:'This article is too large for Reader. Load the original page instead.'});
      return json;
    } catch (_) {
      return JSON.stringify({url:originalURL,error:'Reader could not extract this page. Load the original page instead.'});
    }
    """#

    static let browser = #"""
    function readReaderTab(app, safari, target, source) {
      if (!app.running()) return {captureError:'The browser is no longer running.'};
      const windows = app.windows();
      const w = target ? windows.find(value => String(value.id()) === target.windowID) : windows[0];
      if (!w) return {captureError:'The browser window closed. Reopen Read & note from the page you want.'};
      const tabs = w.tabs();
      const tab = target ? (safari ? tabs[target.index - 1] : tabs.find(value => String(value.id()) === target.tabID)) : (safari ? w.currentTab() : w.activeTab());
      if (!tab) return {captureError:'The browser tab closed. Reopen Read & note from the page you want.'};
      const url = tab.url() || '';
      const title = (safari ? tab.name() : tab.title()) || url;
      const result = {url:url,title:String(title).slice(0,10000)};
      if (!/^https?:\/\//i.test(url)) return {captureError:'Open a web page in your browser first.'};
      if (target && url !== target.url) return {captureError:'The browser tab changed. Reopen Read & note from the page you want.'};
      result.readerTarget = {windowID:String(w.id()), tabID:safari ? '' : String(tab.id()), index:tabs.findIndex(value => safari ? value.url() === url : String(value.id()) === String(tab.id())) + 1, url:url};
      // URL/title capture does not execute JavaScript in the browser tab.
      if (!source) return result;
      // Safari exposes indices, not stable tab IDs. Duplicate URLs are ambiguous after a reorder.
      if (safari && tabs.filter(value => value.url() === url).length !== 1) {
        result.captureError = 'This Safari window has multiple copies of this page. Load the original page, or close the duplicate tabs.';
        return result;
      }
      try {
        const raw = safari ? app.doJavaScript(source, {in:tab}) : tab.execute({javascript:source});
        if (typeof raw !== 'string' || raw.length > 400000) throw new Error('Invalid article');
        const value = JSON.parse(raw);
        if (tab.url() !== url || value.url !== url || (safari && w.tabs().filter(value => value.url() === url).length !== 1)) {
          result.captureError = 'The browser tab changed. Reopen Read & note from the page you want.';
          return result;
        }
        if (value.article) result.article = value.article;
        else result.captureError = value.error || 'Reader could not find an article. Load the original page instead.';
      } catch (_) {
        result.captureError = 'Reader needs “Allow JavaScript from Apple Events” in your browser’s developer settings. Enable it, then try Reader again. Original works without it.';
      }
      return result;
    }
    """#
}
