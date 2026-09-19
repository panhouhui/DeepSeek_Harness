---
description: "在 Windows 上配置 API Key，并通过 Kanai 网关启动 DeepSeek-V4.1-Flash。"
---
# Kanai DeepSeek 接入

[English](README.md) | 中文

## 概述

此配置将现有 Web 和 headless 配置接到 `https://api.kanai.world:6860/v1`，使用模型 `deepseek-v4.1-flash`。Harness 在你的电脑上运行，通过此网关调用模型服务器；仓库不包含模型权重。以下命令均在仓库根目录的 PowerShell 7（`pwsh`）中运行。

## 目录

- [首次配置与 API Key](#setup)
- [启动](#start)
- [配置](#configuration)
- [验证](#verification)

<a id="setup"></a>
## 首次配置与 API Key

安装 Node.js 22.x 中的 22.19 或更高版本，或 Node.js 24 及以上版本，以及 pnpm 11.7.0。安装工作区依赖并构建：

```powershell
pnpm install --frozen-lockfile
pnpm run build
```

在仓库外创建 `%USERPROFILE%\.dsh-kanai` 文件夹，将模型 API Key 保存在该文件夹的 `.env` 文件中。对于 Windows 用户 `pc`，完整路径为 **`C:\Users\pc\.dsh-kanai\.env`**；其他用户使用各自的用户目录。文件名必须是 `.env`，不能是 `.env.txt`。以 UTF-8 编码保存以下内容，并将 `YOUR_MODEL_API_KEY` 替换成实际密钥：

```dotenv
KANAI_API_KEY=YOUR_MODEL_API_KEY
```

此网关配置使用变量名 `KANAI_API_KEY`。实际密钥只保存在本地文件中，不要写入仓库、YAML 配置、截图或 GitHub。启动器不会从 Python 调用脚本读取密钥。更换密钥后，编辑此文件并重启 Harness。继承的 `KANAI_API_KEY` 环境变量或仓库 `.env` 中的值可能覆盖用户目录中的配置；更换密钥时应移除冲突值。

将现有模型调用脚本所在目录中的网关证书 `kanai-local-api-ca.crt` 复制到同一个 `.dsh-kanai` 文件夹。对于用户 `pc`，需要的文件为：

```text
C:\Users\pc\.dsh-kanai\
  .env
  kanai-local-api-ca.crt
```

在其他电脑配置时，请向模型服务管理员获取密钥和 CA 证书。仓库不包含这两个文件。任何一个文件缺失时，启动器都会报文件缺失错误。不要通过关闭 TLS 校验来绕过证书缺失问题。

<a id="start"></a>
## 启动

启动网页界面，再打开终端打印的带认证信息的地址：

```powershell
pwsh -NoProfile -File .\start-kanai.ps1 -NoOpen
```

默认地址为 `http://127.0.0.1:3000`；首次打开的浏览器需要使用终端打印的 token 地址。`-Port` 可指定其他端口。省略 `-NoOpen` 会让 Harness 打开浏览器。前台运行时按 Ctrl+C 停止服务。

执行一次任务后退出：

```powershell
pwsh -NoProfile -File .\start-kanai.ps1 -Profile headless -WebSearch off -MaxTokens 256 -Prompt 'Reply with exactly FINAL_CONNECTION_OK. Do not use tools.'
```

默认 `-Mode fast` 关闭思考。`normal` 和 `thinking` 请求强度 20；`max` 请求强度 100，并默认使用 262,144 输出 token。其他模式默认 65,536。显式 `-MaxTokens` 会覆盖输出上限。`-WebSearch off|auto|force` 控制网关联网字段，默认 `auto`。这些参数控制请求；服务器决定某次回答是否需要思考或联网。

<a id="configuration"></a>
## 配置

启动器使用 `%USERPROFILE%\.dsh-kanai` 作为独立的 Harness 数据目录。密钥和证书文件见[首次配置](#setup)。会话历史、用户设置和运行配置也保存在此目录中。

启动器在 Node 启动前设置 `NODE_EXTRA_CA_CERTS`，并通过 `NO_PROXY=*` 使本进程直连；TLS 校验保持开启。退出时恢复父 PowerShell 的环境变量。

[`cordis.patch.yml`](cordis.patch.yml) 配置网关、模型、文本输入，以及调用脚本声明的 1,048,576 token 上下文容量。[`request-fields.mjs`](request-fields.mjs) 通过已有 DeepSeek 请求扩展注册表添加 `chat_template_kwargs`、`enable_web_search` 和 `priority`。原生适配器继续负责消息、流式用量和工具调用。Low/high 思考选项映射为 20，max 映射为 100，off 映射为 `enable_thinking: false`；标题请求保持关闭思考。

覆盖配置关闭官方 DeepSeek 会话上传、插件清单上传及独立的官方搜索提供方。网关搜索使用 `enable_web_search`，标准 URL 抓取工具仍然可用。标题和上下文压缩请求始终将网关搜索设为 `off`。此配置未声明图片输入。已保存的模型选择和设置仍按照 Harness 原有规则优先于启动默认值。

<a id="verification"></a>
## 验证

构建后运行不需要密钥的插件测试：

```powershell
node --test apps/cli/config/examples/kanai/request-fields.test.mjs
```

测试通过 Cordis Loader 加载插件，检查模式映射、辅助请求的联网策略、其他模型不受影响、配置校验和资源释放。网关接受配置的密钥后，上面的 headless 命令应返回 `FINAL_CONNECTION_OK`。HTTP 401 或 403 表示认证或访问失败，请检查密钥和账户权限。证书错误需要配置网关的受信 CA 文件。本地验证记录、会话数据和浏览器认证令牌不包含在仓库中。
