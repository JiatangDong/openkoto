// 原版模式的 JS 桥：把 WKWebView 里的滚动与选区回传给 Swift。
//
// 刻意保持极小，并且**不改动书本身的样式**——原版模式的全部意义就是还原排版。
// 只做三件事：上报就绪、上报阅读进度、上报选区（含屏幕矩形，供原生浮层定位）。
(function () {
  "use strict";
  if (window.__okotoBridgeInstalled) return;
  window.__okotoBridgeInstalled = true;

  var post = function (name, payload) {
    try {
      window.webkit.messageHandlers.okoto.postMessage({
        name: name,
        payload: payload || {},
      });
    } catch (e) {
      /* 桥不在（预览/测试）时静默 */
    }
  };

  // 竖排（vertical-rl）是横向滚动，且**从右往左**读：
  // 直接用 scrollLeft 会得到反的进度，必须取反。
  var isVertical = function () {
    var mode = window.getComputedStyle(document.documentElement).writingMode ||
      window.getComputedStyle(document.body).writingMode || "";
    return mode.indexOf("vertical") === 0;
  };

  var readingFraction = function () {
    if (isVertical()) {
      var maxX = document.documentElement.scrollWidth - window.innerWidth;
      if (maxX <= 0) return 0;
      var x = window.pageXOffset || document.documentElement.scrollLeft || 0;
      var mode = window.getComputedStyle(document.documentElement).writingMode || "";
      // vertical-rl：起点在最右侧
      return mode.indexOf("vertical-rl") === 0 ? 1 - x / maxX : x / maxX;
    }
    var maxY = document.documentElement.scrollHeight - window.innerHeight;
    if (maxY <= 0) return 0;
    var y = window.pageYOffset || document.documentElement.scrollTop || 0;
    return Math.min(Math.max(y / maxY, 0), 1);
  };

  var throttle = function (fn, wait) {
    var last = 0;
    var timer = null;
    return function () {
      var now = Date.now();
      var remaining = wait - (now - last);
      if (remaining <= 0) {
        last = now;
        fn();
      } else if (!timer) {
        timer = setTimeout(function () {
          timer = null;
          last = Date.now();
          fn();
        }, remaining);
      }
    };
  };

  window.addEventListener(
    "scroll",
    throttle(function () {
      post("scroll", { fraction: readingFraction() });
    }, 250),
    { passive: true }
  );

  // 选区定位符：body 起的子节点路径 + 文本偏移。
  // 刻意不用 EPUB CFI——那是规范级工程量，而我们是这本书唯一的阅读器。
  var pathTo = function (node) {
    var parts = [];
    while (node && node !== document.body) {
      var parent = node.parentNode;
      if (!parent) break;
      var index = Array.prototype.indexOf.call(parent.childNodes, node);
      parts.unshift(index);
      node = parent;
    }
    return parts.join("/");
  };

  var locatorFor = function (range) {
    return (
      pathTo(range.startContainer) + ":" + range.startOffset +
      "-" + pathTo(range.endContainer) + ":" + range.endOffset
    );
  };

  var reportSelection = function () {
    var selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
      post("selectionCleared", {});
      return;
    }
    var text = selection.toString();
    if (!text || !text.trim()) {
      post("selectionCleared", {});
      return;
    }
    var range = selection.getRangeAt(0);
    var rects = Array.prototype.map.call(range.getClientRects(), function (r) {
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    });
    post("selection", { text: text, locator: locatorFor(range), rects: rects });
  };

  document.addEventListener("selectionchange", throttle(reportSelection, 120));

  // 定位符 → Range。路径解析不到（书被换过版本）时返回 null，交给 Swift 走兜底重锚。
  var nodeAt = function (path) {
    if (path === "") return document.body;
    var node = document.body;
    var parts = path.split("/");
    for (var i = 0; i < parts.length; i++) {
      var index = parseInt(parts[i], 10);
      if (!node || !node.childNodes || index >= node.childNodes.length) return null;
      node = node.childNodes[index];
    }
    return node;
  };

  var rangeFromLocator = function (locator) {
    var halves = String(locator).split("-");
    if (halves.length !== 2) return null;
    var start = halves[0].split(":");
    var end = halves[1].split(":");
    var startNode = nodeAt(start[0]);
    var endNode = nodeAt(end[0]);
    if (!startNode || !endNode) return null;
    try {
      var range = document.createRange();
      range.setStart(startNode, parseInt(start[1], 10));
      range.setEnd(endNode, parseInt(end[1], 10));
      return range;
    } catch (e) {
      return null;
    }
  };

  // 找不到定位符时按原文全文搜索——书重排过也不至于丢标记。
  var rangeFromText = function (text) {
    if (!text) return null;
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    var needle = text.replace(/\s+/g, "");
    if (!needle) return null;
    var node;
    while ((node = walker.nextNode())) {
      var content = node.nodeValue || "";
      var index = content.replace(/\s+/g, "").indexOf(needle.slice(0, 20));
      if (index < 0) continue;
      var raw = content.indexOf(needle.slice(0, 5));
      if (raw < 0) continue;
      try {
        var range = document.createRange();
        range.setStart(node, raw);
        range.setEnd(node, Math.min(raw + needle.length, content.length));
        return range;
      } catch (e) {
        return null;
      }
    }
    return null;
  };

  var HIGHLIGHT_NAME = "okoto-highlight";

  window.OK = {
    // 重放划线。优先用 CSS Custom Highlight API（iOS 17.4+），不支持时退到 <mark> 包裹。
    applyMarks: function (json) {
      var marks;
      try {
        marks = JSON.parse(json);
      } catch (e) {
        return;
      }
      var ranges = [];
      for (var i = 0; i < marks.length; i++) {
        var range = rangeFromLocator(marks[i].locator) || rangeFromText(marks[i].text);
        if (range) ranges.push(range);
      }

      if (window.CSS && CSS.highlights && window.Highlight) {
        CSS.highlights.delete(HIGHLIGHT_NAME);
        if (ranges.length) {
          CSS.highlights.set(HIGHLIGHT_NAME, new Highlight.apply(null, ranges));
        }
        return;
      }
      // 回退：逐个包 <mark>。surroundContents 遇到跨元素的区间会抛错，忽略即可。
      for (var j = 0; j < ranges.length; j++) {
        try {
          var element = document.createElement("mark");
          element.className = "ok-hl";
          ranges[j].surroundContents(element);
        } catch (e) {
          /* 跨元素区间，跳过 */
        }
      }
    },
    scrollToFraction: function (fraction) {
      if (isVertical()) {
        var maxX = document.documentElement.scrollWidth - window.innerWidth;
        var mode = window.getComputedStyle(document.documentElement).writingMode || "";
        var target = mode.indexOf("vertical-rl") === 0
          ? (1 - fraction) * maxX : fraction * maxX;
        window.scrollTo(target, 0);
        return;
      }
      var maxY = document.documentElement.scrollHeight - window.innerHeight;
      window.scrollTo(0, fraction * maxY);
    },
    clearSelection: function () {
      var selection = window.getSelection();
      if (selection) selection.removeAllRanges();
    },
  };

  // 划线样式。只注入这一条，其余一律不动——原版模式的全部意义就是还原排版。
  var style = document.createElement("style");
  style.textContent =
    "::highlight(" + HIGHLIGHT_NAME + "){background-color:rgba(255,214,10,0.35);}" +
    "mark.ok-hl{background-color:rgba(255,214,10,0.35);color:inherit;}";
  document.head && document.head.appendChild(style);

  var announceReady = function () {
    post("ready", {
      writingMode: isVertical() ? "vertical" : "horizontal",
      contentLength: (document.body.innerText || "").length,
    });
  };

  if (document.readyState === "complete" || document.readyState === "interactive") {
    announceReady();
  } else {
    document.addEventListener("DOMContentLoaded", announceReady);
  }
})();
