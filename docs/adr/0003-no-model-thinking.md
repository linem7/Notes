# Organize 关闭模型思考

Notes 的 Organize 要的是快，不是精准：结果是一条用户随时可以手改的 Draft。思考会明显拖慢出结果的时间。

沿用 Chatbot [ADR-0002](https://github.com/linem7/Chatbot/blob/main/docs/adr/0002-no-model-thinking.md) 中 OpenAI 兼容协议的部分：按 Platform 发各自的关闭字段；关不掉的模型发它支持的最低档。默认 Model 是 `deepseek-flash`。

## Consequences

- 日期换算、拆分任务偶尔会错，靠 Draft 预览让用户在保存前改正。
