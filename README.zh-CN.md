# Bipara

[English](README.md) · 简体中文

Bipara 是原生 macOS 中英长文翻译与对照阅读应用，支持左右对照、交替段落、
词句对应和独立多文档标签。

应用使用 Swift 管理原生界面、文档和任务，内置 Python worker 通过 LangChain
调用模型。最终用户无需安装 Python 或运行服务器。支持配置 OpenAI、Kimi、
GLM 和 DeepSeek；调用需要网络、符合资格的账户，并可能产生服务商费用。

当前为实验性源码预览。本文不代表已有公开发行或合格安装包。真实服务商的
语义质量、延迟和费用尚未完整验收，原生 UI 与无障碍验收也未完成。

## 安装与使用

源码构建请按下方开发说明操作。源码就绪需要公共内容、历史与身份审查，以及
离线回归检查；当前结果和阻碍见[验证状态](docs/validation.md)。

每个正式版本仍必须有受保护的版本 tag，以及经过 Developer ID 签名、公证的
可安装 arm64 DMG，并针对该包的精确校验和完成干净安装、升级和最低系统验收。
这些发行门禁独立于源码就绪检查；此处不承诺发布日期或下载地址。

在 Settings 中添加模型配置，填写实际模型、API Base URL 和密钥，选择 Active
Model。粘贴文本或打开 UTF-8 txt 文件后翻译；切换阅读布局无需重新翻译。
可保存为 bipara 文档，或显式导出、复制文本。发送文档前请阅读
[隐私说明](PRIVACY.md)。

目标平台为 Apple Silicon、macOS 14+；部署目标和实际验证版本分别记录。
VoiceOver、纯键盘流程、增强对比度和减少动态效果仍需完整原生验收，
离线 fixture 不能替代这些证据。

## 开发

需要完整 Xcode、用于工具脚本的 Python 3.11+ 和 uv。worker 使用锁定的
CPython 3.13 环境；原生测试需要 macOS 图形会话。默认检查无需模型密钥。

```sh
script/setup_local.sh
uv sync --project Worker --frozen --group dev
script/check.sh
script/build_and_run.sh
script/build_dmg.sh --development
```

临时过程资料保存到被忽略的 .local；长期非秘密个人上下文以私有知识库为入口，
原始证据和历史档案放仓库外。有效工程要求和正常开发历史由项目公开维护。
私人资料和知识库均不参与构建。详见
[内容边界](docs/repository-boundaries.md)和[贡献指南](CONTRIBUTING.md)。

默认检查覆盖工具、worker 打包、Swift/Python 离线测试和原生构建。
真实模型、原生 UI 和正式发行分别验收，见[测试说明](Tests/README.md)。
正式版本从 tag 构建 DMG，安装验收后发布，见[发行流程](docs/releasing.md)。

## 项目资料

- [需求](docs/requirements.md)、[架构](docs/architecture.md)、[设计原则](docs/design-principles.md)
- [开发计划](docs/development-plan.md)、[开源准备实施计划](docs/open-source-preparation.md)
- [Prompt 与语料](prompts/README.md)、[安全报告](SECURITY.md)
- [图标来源](docs/design/icons/README.md)、[依赖许可](Worker/THIRD_PARTY_NOTICES.md)

项目自有内容采用 [MIT](LICENSE)。保留第三方归属；[worker 许可说明](Worker/THIRD_PARTY_NOTICES.md)
描述许可收集方式，外部 dylib 的完整许可覆盖及法律兼容性仍未验证，见[验证状态](docs/validation.md)。
