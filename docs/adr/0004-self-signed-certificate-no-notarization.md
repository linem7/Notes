# 用固定自签名证书签名，不做公证

沿用 Chatbot [ADR-0005](https://github.com/linem7/Chatbot/blob/main/docs/adr/0005-self-signed-certificate-no-notarization.md)：自用工具，不付 Apple Developer 年费。本机构建用固定的自签名证书 `Notes Self-Signed`，保证 Keychain 里 API key 的访问权限在重新构建后不变；Release 安装包首次打开需要在 Privacy & Security 里 Open Anyway。

也可以复用 Chatbot 的证书，但用独立证书让两个 app 的签名身份互不影响；创建步骤和 Chatbot README 相同，只是名字不同。
