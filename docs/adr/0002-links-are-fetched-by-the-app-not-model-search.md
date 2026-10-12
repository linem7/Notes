# 网页链接由 app 本地抓取，不用模型侧联网搜索

Notes 需要读用户给的网页链接，但模型调用保持「不联网」：DeepSeek 没有原生搜索，而且 Notes 要的是「读这一个页面」，不是「去搜」。

所以由 app 用离屏 WKWebView 加载链接，用 Readability.js 抽正文交给模型，同时把正文和 PDF 快照存进本地，任务执行时可以回看，原网页失效也不受影响。

## Considered Options

- **模型侧搜索 / 抓取**（OpenRouter、百炼的搜索）：否决。DeepSeek 直连不支持；结果不能本地保存。
- **URLSession 拉 HTML 再自己解析**：否决。很多页面靠 JavaScript 渲染，拿不到正文；也做不了 PDF 快照。

## Consequences

- 需要登录的页面抓不到正文，v1 不处理。
- 抓取不带用户的 cookie（非持久的 data store），不会泄露登录态。
