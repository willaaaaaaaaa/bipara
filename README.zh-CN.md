# Bipara

[English](README.md) · 简体中文

Bipara 是一款由大语言模型（LLM）驱动的原生 macOS 翻译与双语对照阅读应用，专注于中英长文，支持左右对照、交替段落、词句对应和独立多文档标签。

应用使用 Swift 管理原生界面、文档和任务，内置 Python worker 通过 LangChain 调用模型。最终用户无需安装 Python 或运行服务器。模型连接支持 OpenAI Responses 和 Anthropic Messages，统一通过自定义表单填写名称、接口协议、模型 ID、推理力度、API Base URL 和 API 密钥。用户自行选择兼容的模型和参数；调用需要网络、符合资格的账户，并可能产生服务商费用。

Bipara 目前处于实验阶段。真实服务商的语义质量、延迟和费用尚未完整验收，原生 UI 与无障碍验收也未完成。

## 安装与使用

源码构建请按下方开发说明操作。源码就绪需要公共内容、历史与身份审查，以及离线回归检查；当前结果和阻碍见[验证状态](docs/validation.md)。

每个公开安装版本必须有受保护的版本 tag 和可安装 arm64 DMG，并针对该包的精确校验和在维护者本机完成安装和升级验收。发布说明记录实际测试的 macOS 版本；本机结果不代表干净机器或跨系统验收。首版采用 ad-hoc 签名，未经 Apple 公证，也没有经过验证的 Developer ID 身份；macOS 可能要求针对本应用选择“仍要打开”。详见[安装与信任说明](docs/releasing.md#install-and-publish)。可用安装包、校验和及各版本的验收范围见 [GitHub Releases](https://github.com/willaaaaaaaaa/bipara/releases)。

在 Settings 中添加模型配置，填写实际模型、API Base URL 和密钥，选择 Active Model。粘贴文本或打开 UTF-8 txt 文件后翻译；切换阅读布局无需重新翻译。可保存为 bipara 文档，或显式导出、复制文本。发送文档前请阅读 [隐私说明](PRIVACY.md)。

Bipara 面向 Apple Silicon 上的 macOS 26 和 27，以及兼容 Intel Mac 上的 macOS 26，最低部署版本为 macOS 26.0。两种芯片使用独立安装包；macOS 27 不支持 Intel，无法运行 macOS 26 的旧款 Intel Mac 不在支持范围。Intel 安装包不要求维护者运行验收。验收仅在维护者本机系统上进行；其他目标系统未经维护者实测，用户需自行确认其设备上的兼容性。实际测试环境和安装证据见验收状态及各版本发布说明。VoiceOver、纯键盘流程、增强对比度和减少动态效果仍需完整原生验收。

## 开发

需要完整 Xcode、用于工具脚本的 Python 3.12+ 和 uv。worker 使用锁定的 CPython 3.13 环境；原生测试需要 macOS 图形会话。默认检查无需模型密钥。

```sh
script/setup.sh
uv sync --project Worker --frozen --group dev
script/check.sh
script/build_and_run.sh
script/build_dmg.sh --development
```

初始化脚本为当前检出目录安装 Git hooks 和固定版本的检查工具。提交前请选择用于公开的 Git 作者身份。配置步骤见[贡献指南](CONTRIBUTING.md)，开发产物和凭据的处理规则见[内容边界](docs/repository-boundaries.md)。

默认检查覆盖工具、worker 打包、Swift/Python 离线测试和原生构建。真实模型、原生 UI 和正式发行分别验收，见[测试说明](Tests/README.md)。正式版本从 tag 构建 DMG，安装验收后发布，见[发行流程](docs/releasing.md)。

## 项目资料

- [需求](docs/requirements.md)、[架构](docs/architecture.md)、[设计原则](docs/design-principles.md)
- [开发计划](docs/development-plan.md)、[开源就绪检查](docs/open-source-preparation.md)
- [Prompt 与语料](prompts/README.md)、[支持与问题反馈](SUPPORT.md)、[安全报告](SECURITY.md)
- [图标来源](docs/design/icons/README.md)、[依赖许可](Worker/THIRD_PARTY_NOTICES.md)

项目自有内容采用 [MIT](LICENSE)。保留第三方归属；[worker 许可说明](Worker/THIRD_PARTY_NOTICES.md) 描述许可收集方式，外部 dylib 的完整许可覆盖及法律兼容性仍未验证，见[验证状态](docs/validation.md)。
