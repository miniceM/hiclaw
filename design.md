# HiClaw 项目初始化设计文档

## 什么是 HiClaw

HiClaw 是一套开箱即用的开源 Agent Teams 系统，可以基于 IM 即时通讯工具实现多 Agent 协同工作管理。基于 IM 可以同时支持多 Agent 自主协同，以及 Human x Agent 的混合协同（Human in the loop）。
这个系统的核心组成如下：
- AI网关：统一管理多个 Agent 的 LLM 调用凭证，Token 计量，以及不同 Agent 的权限
- Martix Home Server&Web Client：作为 Agent 间基于 Matix 协议进行 IM 通信的服务器，并提供开箱即用的 IM 工具
- Owner Agent：可以基于 Martix 协议和 Human 通信，可以对接AI网关访问 LLM，仅接受 Human 指示操作本地系统环境，同时协助 Human 完成 Worker 的生命初始化
- Worker Agent：可以基于 Matrix 协议和其他 Agent 以及 Human 通信，可以对接AI网关访问 LLM，并操作本地沙箱工作环境

需要部署的组件以及构成如下：
1. hiclaw-owner-agent 容器：
   - AI 网关
   - Martix Home Server
   - Martix Web Client
   - Owner Agent
2. hiclaw-worker-agent 容器：
   - Worker Agent

提供两种工作模式：
1. Owner Agent 模式：仅部署 hiclaw-owner 容器即可，用法上跟 OpenClaw 一致，但提供了开箱即用的 IM 工具，以及灵活切换模型的 AI 网关
2. Agent Teams 模式：
   - Owner Agent 用于统一管理 AI 网关和 Martix Home Server；Worker Agent 用于执行具体任务
   - Owner Agent 也一样接入 IM，但不参与具体任务执行，仅限真人管理员账号进行对话，实现核心系统的安全隔离，不会导致 LLM Key 等信息被提示词注入后泄漏

第一版组件实现：
- AI网关：基于 [Higress](https://github.com/alibaba/higress) 实现
- Martix Home Server：基于 [Tuwunel](https://github.com/matrix-construct/tuwunel) 实现
- Martix Web Client：基于 Element Web 实现
- Agent：基于 [OpenClaw fork](https://github.com/higress-group/openclaw) 实现

对 OpenClaw fork 改动点如下：
- 弃用原本的 LLM 模型代理相关逻辑，由 AI 网关统一完成 LLM 代理功能（OpenClaw相关代码暂未移除，但实际不使用）
- 定制 SOUL.md，专注在多 Agent 协作场景，做安全性加固，同时优化 Token 开销

## 用例设计

### Owner Agent 安装和配置

用户通过 hiclaw-install 脚本完成 Owner Agent 的安装和配置。这个脚本通过交互式命令的方式，让用户给出以下信息：
- LLM Provider，默认使用的模型，以及对应的 API Key
- 管理员用户名和密码
- Matrix Homeserver 的域名（选填）
- Matrix Web client 的域名（选填）
- AI 网关的接入点域名 （选填）

用户配置好后，会自动帮用户在 Matrix 服务器里注册好两个账号：
- 真人账号（例如：@johnlanni:matrix-local.hiclaw.io:8080）
- Owner Agent 账号（例如：@owner:matrix-local.hiclaw.io:8080）

提示用户可以打开 Element Web 输入管理员用户名和密码，并将 Owner Agent 账号加入到房间里进行对话管理。

同时也提示用户可以安装其他其他更易用的 Matrix 客户端，支持在 Windows/Mac/IOS/Android 等系统上使用，例如可以安装 fluffychat：https://fluffy.chat/en/

#### 实现说明

##### Matrix Homeserver 的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：matrix-local.hiclaw.io；在创建 Higress 的 Matrix Homeserver 相关的路由时，需要配置上这个域名
- 默认域名 matrix-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Owner 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Owner Agent 机器所在 IP；后续可以直接使用这个地址作为 Matrix Homeserver 的地址： http://matrix-local.hiclaw.io:8080
- 这个域名要作为 Matrix Homeserver 的地址在配置项中纪录下来，未来接受 Human 指令初始化 Worker Agent 时要给出此配置

##### Matrix Web client 的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：matrix-client-local.hiclaw.io；在创建 Higress 的 Matrix web client 相关的路由时，需要配置上这个域名
- 默认域名 matrix-client-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Owner Agent 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Owner Agent 机器所在 IP；后续可以直接使用这个地址作为 Matrix Web client 的地址： http://matrix-client-local.hiclaw.io:8080
- 这个域名要作为 Matrix Web client 的地址在配置项中纪录下来

##### AI 网关的域名

- 用户填写这个域名时，表明用户会自己对这个域名做DNS解析；用户未填时，使用默认域名：llm-local.hiclaw.io；在创建 Higress 的 AI 路由时，需要配置上这个域名
- 默认域名 llm-local.hiclaw.io 会被解析到 127.0.0.1，但也需要提醒用户，如果 Owner Agent 和 Worker Agent 不在一台机器上，要自己配置这个域名解析到 Owner Agent 机器所在 IP；后续直接使用这个地址作为 AI 网关的接入点地址： http://llm-local.hiclaw.io:8080
- 这个域名要作为 AI Gateway Endpoint 的地址在配置项中纪录下来，未来接受 Human 指令初始化 Worker Agent 时要给出此配置

#### Owner Agent 在 OpenClaw 基础上的改动

在 openclaw.json 的配置里需要默认配置好 matrix 的相关配置，此外限制这个 Owner Agent 只能被真人账号访问，例如：
```js
  "channels": {
    "matrix": {
      "enabled": true,
      "homeserver": "http://matrix-local.hiclaw.io:8080",
      "accessToken": "xxxxxxxx",
      "deviceName": "xxxxxxx",
      "groupPolicy": "allowlist",
      "dm": {
        "policy": "allowlist",
        "allowFrom": [
          "@johnlanni:matrix-local.hiclaw.io:8080"
        ]
      },
      "groupAllowFrom": ["@johnlanni:matrix-local.hiclaw.io:8080"],
      "groups": {
        "*": { allow: true }
      }
    }
  }
```

Owner Agent 访问 Higress AI 网关的 API key，需要通过调用 higress console 的 POST /v1/consumers 接口创建，consumer 名称和 Matrix 用户名保持一致（例如: @admin:matrix-local.hiclaw.io:8080）, 使用 key-auth 认证方式，来源选择 BEARER 方式，是用脚本生成的随机生成的安全系数高的Key。

根据用户配置的模型， 在 openclaw.json 的配置里需要配置好模型相关的配置，举例来说：

```js
  "models": {
    "mode": "merge",
    "providers": {
      "bailian": {
        "baseUrl": "http://llm-local.hiclaw.io:8080/v1",
        "apiKey": "YOUR_API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "qwen3-max-2026-01-23",
            "name": "qwen3-max-thinking",
            "reasoning": false,
            "input": [
              "text"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 262144,
            "maxTokens": 65536
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "bailian/qwen3-max-2026-01-23"
      },
      "models": {
        "bailian/qwen3-max-2026-01-23": {
          "alias": "qwen3-max-thinking"
        }
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    }
  },
```
此外，需要给这个 Owner Agent 的 OpenClaw 预置好两个 Skill
1. 管理 AI 网关的 Skill：通过访问 AI 网关的 console api 来实现管控，console 的地址为：http://127.0.0.1:8001, 使用 basic-auth 进行认证，前面已经说过，用户名和密码就是管理员用户名和密码；api 文档参考当前目录下 higress-console-api.yaml
2. 管理 matrix server 的 Skill：

### Worker Agent 安装和配置

在完成服务端安装和配置后，可以在 Matrix 客户端里跟 Owner Agent 进行对话来对客户端账号进行初始化，同时给出一键安装命令。

例如用户可以这样说：“我需要增加一个 Agent 员工，名字叫做 Alice”

Owner Agent 的答复中会包含以下信息：
- 这个 Alice 账号的 Matrix 用户名和密码，用户名需要英文小写，密码是用脚本生成的随机生成的安全系数高的密码。
- 一行安装命令，是使用 hiclaw-install 脚本来完成这个 Worker Agent 安装的，这个命令需要给出以下参数：
  1. Agent 的名字
  2. 给 openClaw 集成这个 Alice 账号用的 matrix token
  3. Matrix Homeserver 的地址
  3. Higress AI网关的接入地址和 API Key

提示用户，这个 Bot 的账号密码可以保留好，不要泄漏，一般情况下也无需登录 Bot 的账号，后续安装流程不依赖这个用户名和密码。

用户主要使用这个安装命令，在一台可以和 Server 所在网络联通的机器上完整 Worker Agent 安装。
并在用户执行完这个安装命令后，提醒用户 “Alice 已经完成初始化，可以通过 Element Web 搜索账号：@alice:127.0.0.1:8080 ，加入到房间中指派任务” 


#### 实现说明

##### matrix token 获取方式

matrix token按以下方式请求基于Higress路由的matrix server获取：
  ```bash
        curl --request POST \
        --url http://127.0.0.1:8080/_matrix/client/v3/login \
        --header 'Content-Type: application/json' \
        --data '{
          "type": "m.login.password",
          "identifier": {
            "type": "m.id.user",
            "user": "alice"
          },
          "password": "xxxxxx"
        }'
  ```
返回内容如下，取里面的 access_token 字段： 
  ```bash
  {"user_id":"@alice:matrix-local.hiclaw.io:8080","access_token":"xxxxxxxx","home_server":"matrix-local.hiclaw.io:8080","device_id":"VW1Hmtf7UB"}
  ```

##### Higress AI 网关的 API Key

分配给 Worker Agent 的 API key，需要通过调用 higress console 的 POST /v1/consumers 接口创建，consumer 名称和 Matrix 用户名保持一致（例如: @alice:matrix-local.hiclaw.io:8080）, 使用 key-auth 认证方式，来源选择 BEARER 方式，是用脚本生成的随机生成的安全系数高的Key。


### Agent 自主协作



