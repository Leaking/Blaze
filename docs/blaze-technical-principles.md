<callout emoji="🧭" background-color="light-blue">
这份文档从网络工程和 macOS 开发两个视角解释 Blaze：它不是“又一个 HTTP 代理 UI”，而是在本地代理、DNS、路由、Network Extension、tun2socks 之间建立一条完整的数据面，目标是接近 Surge 的透明接管体验。
</callout>

## 先回答几个核心疑问

**为什么有些软件没有配置代理，Blaze 仍然理论上可以接管它的流量？**

因为透明接管不依赖应用自己填写 HTTP/SOCKS 代理。应用仍然以为自己在连接 `www.google.com:443` 或某个 IP，macOS 内核根据路由表把这些 IP 包送进一个虚拟网卡，也就是 Network Extension Packet Tunnel 创建的 `utun` 接口。Blaze 的 System Extension 读取这些原始 IP 包，自己实现 TCP 状态机，再把 TCP payload 转发到本地 SOCKS5 代理，由本地代理根据规则选择 DIRECT 或远端代理节点。

**HTTP 代理、SOCKS5 代理、透明代理是什么关系？**

HTTP/SOCKS5 是显式代理：客户端必须知道代理地址，例如 `127.0.0.1:19080` 或 `127.0.0.1:19081`。透明代理是系统层接管：客户端不知道代理存在，系统把它的 IP 包导入隧道，隧道侧再转成代理请求。

**Surge 的“增强模式/透明代理”大致靠什么实现？**

Surge 的完整实现细节不是公开协议，但从 macOS 平台能力和可观察行为看，它组合了本地代理、规则引擎、DNS 策略、虚拟网卡/Network Extension、fake-ip 映射、UDP/QUIC 策略和出站绕过。Blaze 要对齐的不是某个单点 API，而是这套“从应用 socket 到远端代理节点”的闭环。

**Blaze 当前处在哪个阶段？**

截至 2026-05-17，Blaze 已有本地 HTTP 代理、SOCKS5 代理、Packet Tunnel/System Extension scaffold、初步 tun2socks TCP forwarding、DNS fake-ip/AAAA 抑制、非 DNS UDP 的 ICMP unreachable 回退策略、上游绕过路由诊断和签名/公证工程链路。它还没有完整达到 Surge 级别：IPv6、UDP relay 默认启用、复杂 TCP 拥塞/窗口、可靠连接生命周期、规则覆盖面、性能和 UI 诊断仍需继续打磨。

## 一张图理解 Blaze 的数据路径

<whiteboard type="blank"></whiteboard>

## macOS 上的三种代理层级

| 层级 | 入口 | 应用是否知道代理 | 能接管的流量 | 典型用途 |
| --- | --- | --- | --- | --- |
| 应用内代理配置 | App 自己的设置 | 知道 | 该 App 显式走代理的 HTTP/SOCKS 流量 | 开发调试、单应用代理 |
| 系统 HTTP/SOCKS 代理 | macOS Network Service proxy settings | 多数支持系统代理的 App 知道 | 遵循系统代理的 HTTP/HTTPS/SOCKS 流量 | 浏览器、常规 App |
| Packet Tunnel 透明接管 | Network Extension + utun + 路由 | 不知道 | 被路由导入隧道的 IP 流量 | VPN、透明代理、增强模式 |

Blaze 早期功能主要覆盖前两层：启动 `127.0.0.1:19080` HTTP 代理和 `127.0.0.1:19081` SOCKS5 代理，再把 macOS 的系统代理指向它。这样对浏览器有效，但对不读系统代理的程序无效。

透明接管必须进入第三层：把默认路由交给 Packet Tunnel，让系统把目标流量作为 IP 包送进 Blaze 的 tunnel provider。这个路径不需要应用配代理，代价是 Blaze 自己要处理更多网络协议细节。

## HTTP 代理是怎么工作的

HTTP 代理是应用层协议。客户端明确知道代理存在，并把请求发给代理服务器。

普通 HTTP 请求会使用 absolute-form：

```http
GET http://example.com/path HTTP/1.1
Host: example.com
```

代理看到完整 URL 后，自己去连接 `example.com:80`，再把响应转回客户端。

HTTPS 使用 `CONNECT`：

```http
CONNECT www.google.com:443 HTTP/1.1
Host: www.google.com:443
```

代理先建立到 `www.google.com:443` 的 TCP 连接，然后回复：

```http
HTTP/1.1 200 Connection Established
```

之后代理不理解 TLS 内容，只做字节转发。TLS 握手仍发生在客户端和目标站之间。除非做 MITM 证书安装，否则代理不能看到 HTTPS 明文。

Blaze 的本地 HTTP 代理负责：

- 解析 HTTP 请求和 CONNECT 目标。
- 根据规则引擎选择 DIRECT、Trojan、HTTP、SOCKS5 等上游。
- 对 HTTPS CONNECT 做 TCP tunnel。
- 记录连接事件，用于 Traffic/Logs 面板。

## SOCKS5 代理是怎么工作的

SOCKS5 比 HTTP 代理更底层。它不理解 HTTP 方法，只负责“帮客户端连接某个主机和端口”。

典型流程是：

1. 客户端连接 `127.0.0.1:19081`。
2. 客户端发送认证协商，例如 no-auth。
3. 客户端发送 CONNECT 请求，目标可以是 IPv4、IPv6 或 domain。
4. SOCKS5 代理连接目标或远端代理节点。
5. 连接建立后，双方进入纯字节转发。

SOCKS5 的优点是协议无关：HTTP、HTTPS、SSH、数据库协议都可以通过 SOCKS5 转发。Blaze 的 Packet Tunnel 目前把透明 TCP 流量转发到本地 SOCKS5 listener，本质上是把“IP 包世界”转成“SOCKS5 代理世界”。

## 为什么没有配置代理的软件也能被接管

关键在于操作系统网络栈的位置。

普通 App 调用的是 socket API：

```text
connect("www.google.com", 443)
```

或者先 DNS 解析：

```text
www.google.com -> 142.250.x.x
connect(142.250.x.x, 443)
```

如果没有透明接管，内核根据默认路由把 TCP SYN 发到物理网卡，例如 Wi-Fi `en0/en1`。

启用 Packet Tunnel 后，Network Extension 安装一组网络设置：

- 创建 `utun` 虚拟接口。
- 设置 IPv4 地址，例如 `10.255.0.2`。
- 设置默认路由，把公网流量导入 `utun`。
- 设置 DNS，使 DNS 查询也进入 tunnel 或走受控 DNS。
- 设置 excluded routes，避免本地网段、DNS 服务器、代理上游 IP 被隧道再次捕获。

于是应用发出的 TCP SYN 不再直接出物理网卡，而是变成一段原始 IP packet，被 `NEPacketTunnelFlow.readPackets` 交给 Blaze。

Blaze 必须在用户态模拟目标服务器的一半 TCP 行为：

1. 收到客户端 SYN。
2. 回 SYN-ACK。
3. 收 ACK 后认为连接建立。
4. 收客户端 payload。
5. 把 payload 写入本地 SOCKS5 连接。
6. 从 SOCKS5 上游收到数据后，构造反向 TCP packet 写回 `NEPacketTunnelFlow.writePackets`。

这个过程就是 tun2socks 的核心。它看起来像“把全局流量导到本地代理”，但准确说是：把内核路由导入 tunnel 的 IP 包，在用户态终止 TCP，再桥接到本地 SOCKS5。

## DNS fake-ip 为什么重要

透明代理的一个难点是：规则引擎通常需要域名，但 TCP packet 里只有 IP 地址。

如果应用先问：

```text
www.google.com A ?
```

系统 DNS 返回真实 IP 后，后续 TCP 连接只有目标 IP。到 tunnel 侧时，Blaze 可能只看到：

```text
10.255.0.2:54321 -> 142.250.x.x:443
```

此时规则引擎很难判断这是 `www.google.com`、`youtube.com` 还是某个共享 CDN 域名。

fake-ip 的做法是：DNS 查询进入 tunnel 后，不直接返回真实 IP，而是给域名分配一个保留地址段里的假 IP，例如 `198.18.4.18`，并记录映射：

```text
198.18.4.18 -> www.google.com
```

应用随后连接 `198.18.4.18:443`。Blaze 在 Packet Tunnel 里看到目标 IP 是 fake-ip，就能反查出域名，然后向 SOCKS5 发起 domain-form CONNECT：

```text
SOCKS5 CONNECT www.google.com:443
```

这样规则匹配、SNI 策略、远端 DNS 解析都更接近代理工具的预期。

Blaze 当前还做了 AAAA 抑制：在 IPv6 转发未完成前，对 AAAA 查询返回空结果，减少系统优先走 IPv6 导致的连接失败。

## UDP、QUIC 和为什么会让 Chrome 回退 TCP

现代浏览器访问 Google、YouTube 时经常优先使用 QUIC，也就是 UDP/443。如果透明代理只支持 TCP，不处理 UDP，那么浏览器会尝试 QUIC，但 tunnel 侧无法完整转发。

Blaze 当前对非 DNS UDP 的保守策略是返回 ICMP Destination Unreachable，告诉客户端“这条 UDP 路不通”。Chrome 收到失败信号后通常会回退到 TCP/TLS，也就是 HTTPS over TCP。这个策略不完美，但比静默丢包更好，因为静默丢包会造成长时间等待。

Surge 级别体验最终需要完整 UDP relay：

- DNS UDP 查询要能处理或转 DoH。
- QUIC/UDP 要能按策略代理或拒绝。
- SOCKS5 UDP ASSOCIATE、远端协议 UDP 能力、NAT 映射、超时回收都要稳定。

Blaze 已有本地 SOCKS5 UDP ASSOCIATE 的基础测试和 Packet Tunnel UDP relay 的 gated 实现，但目前仍默认关闭。

## Blaze 当前工程结构

| 模块 | 职责 |
| --- | --- |
| `blaze.app` | macOS SwiftUI 主程序，提供配置、规则、节点、日志、测试和安装入口 |
| Local HTTP Proxy `127.0.0.1:19080` | 显式 HTTP/HTTPS 代理入口，支持 CONNECT 和规则选择 |
| Local SOCKS5 Proxy `127.0.0.1:19081` | 显式 SOCKS5 入口，也是 Packet Tunnel 的 TCP 出口 |
| System Extension | 承载 Packet Tunnel Provider，需要 `packet-tunnel-provider-systemextension` entitlement |
| `PacketTunnelProvider` | 安装 tunnel 网络设置：地址、路由、DNS、排除路由 |
| `PacketTunnelEngine` | 读取 IP packets，处理 TCP/UDP/DNS，做 tun2socks 桥接 |
| DNS fake-ip store | 维护 fake-ip 到域名的映射 |
| 上游连接层 | Trojan/HTTP/SOCKS5/DIRECT 出站，要求绕过 tunnel 回环 |

一个关键工程原则是：**代理自己的上游连接不能再次进入自己的 tunnel**。

否则会形成回环：

```text
App -> tunnel -> local SOCKS -> upstream proxy -> 被默认路由再次送回 tunnel -> local SOCKS -> ...
```

Blaze 当前通过几类方式降低回环风险：

- 把 DNS 服务器和远端代理解析出的 IP 加入 excluded routes。
- 本地代理上游 socket 尽量绑定物理接口，避免走 `utun`。
- 禁止把普通 packet-tunnel-provider profile 冒充 systemextension profile。
- 在诊断面板暴露 Tunnel Bypass 信息。

## Surge 的能力拆解，以及 Blaze 对齐方向

Surge 的用户体验强在“所有细节都被整合成一个稳定系统”。从能力拆解看，大致包括：

| 能力 | Surge 体验 | Blaze 当前状态 | 后续方向 |
| --- | --- | --- | --- |
| 本地 HTTP/SOCKS 代理 | 稳定、可被系统代理或外部客户端使用 | 已实现基础能力 | 增强协议覆盖、错误诊断、连接统计 |
| 透明 TCP 接管 | 大部分 App 无需配置代理 | 初步 Packet Tunnel + tun2socks | 完善 TCP 窗口、重传、FIN/RST、backpressure |
| DNS 策略 | fake-ip、real-ip、规则联动 | fake-ip 与 AAAA 抑制已落地 | 分流 DNS、缓存、污染防护、规则联动 |
| UDP/QUIC | 可配置代理、拒绝或直连 | UDP relay gated，非 DNS UDP 回 ICMP | 完整 UDP relay、QUIC 策略、NAT 生命周期 |
| IPv6 | 可按策略处理 | 暂未完整转发，AAAA 抑制 | IPv6 packet parse/route/fake-ip/relay |
| 规则引擎 | DOMAIN/CIDR/FINAL/策略组等成熟体验 | 已有基础解析和命中记录 | 扩展规则类型、性能优化、可观测性 |
| 工程交付 | 签名、公证、System Extension 安装顺滑 | Developer ID、公证、profile 已跑通 | 自动化构建、版本迁移、错误提示 |

## 为什么 Packet Tunnel 不应该再设置系统 HTTP 代理

这是 Blaze 最近调试中暴露出的一个典型平台坑。

Packet Tunnel 已经通过路由接管流量。如果同时在 `NEPacketTunnelNetworkSettings.proxySettings` 里把系统 HTTP/HTTPS 代理再指向 `127.0.0.1:19080`，流量路径会变成混合模式：

```text
App -> system HTTP proxy -> Blaze HTTP proxy -> upstream proxy
```

而不是纯透明模式：

```text
App socket -> utun packet -> PacketTunnelEngine -> local SOCKS -> upstream proxy
```

混合模式会带来几个问题：

- 一些命令或 App 会走系统代理，而不是测试透明 tunnel。
- Blaze 自己的上游连接可能受到系统代理状态影响。
- tunnel、系统代理、Surge 等其他 Network Extension 同时存在时，路径判断变得困难。
- 透明代理问题会被 HTTP 代理问题掩盖。

因此 Blaze build 24 的方向是：Packet Tunnel 默认不写 `NEProxySettings`，让透明接管回到路由和 tun2socks 这条主路径。系统 HTTP/SOCKS 代理仍然可以作为单独功能保留，但不应该和 Packet Tunnel 的默认透明模式绑定在一起。

## 透明接管的关键难点

**TCP 不是简单字节流复制。**

在显式代理模式下，Blaze 接到的是一个已经由系统 TCP 栈处理好的 socket。但在 Packet Tunnel 模式下，Blaze 收到的是原始 TCP segments。它要处理：

- SYN/SYN-ACK/ACK 三次握手。
- 客户端重传和乱序包。
- receive window 和 backpressure。
- 服务端数据拆包、MSS、分段。
- FIN 半关闭和 RST 异常关闭。
- idle timeout 和资源回收。

**DNS 和连接必须关联起来。**

fake-ip 不是为了“伪造 DNS”本身，而是为了把后续 TCP 连接重新绑定回域名，使规则引擎能工作。

**代理出站必须绕过自己。**

任何远端代理节点连接、DoH 连接、规则集下载、profile 更新，如果被 tunnel 再次捕获，都可能造成回环或假死。

**UDP 不能只靠 TCP 思维处理。**

UDP 没有连接状态，必须自己维护 NAT 表、超时、回包方向、ICMP 错误和协议策略。QUIC 尤其敏感：静默丢包会显著拖慢浏览器体验。

## 开发和验证建议

验证 Blaze 时要分层验证，不要一上来只看“Google 打不开”。

1. 先验证本地 listener：

```shell
lsof -nP -iTCP:19080 -iTCP:19081 -sTCP:LISTEN
curl --proxy http://127.0.0.1:19080 http://www.gstatic.com/generate_204
curl --proxy socks5h://127.0.0.1:19081 http://www.gstatic.com/generate_204
```

2. 再验证 Packet Tunnel 是否 connected：

```shell
scutil --nc status "blaze Packet Tunnel"
route -n get 8.8.8.8
```

3. 再验证 DNS：

```shell
dig www.google.com A
dig www.google.com AAAA
```

4. 最后验证透明路径：

```shell
curl --noproxy '*' http://www.gstatic.com/generate_204
curl --noproxy '*' -I https://www.google.com/generate_204
```

调试时不要 kill Surge，因为当前机器访问 ChatGPT/Codex 依赖 Surge。需要对比时，优先短时间从 Surge UI 关闭开关，测试完成后再恢复。

## 总结

Blaze 要对齐 Surge，真正难点不在“开一个代理端口”，而在把 macOS 的多层网络能力串成稳定的数据面：

- 显式代理负责 HTTP/SOCKS 的标准入口。
- Packet Tunnel 负责把未配置代理的 App 流量导入用户态。
- tun2socks 负责把 IP/TCP packet 转成 SOCKS5 字节流。
- DNS fake-ip 负责把 IP 连接重新绑定到域名规则。
- excluded routes 和物理网卡绑定负责避免代理回环。
- UDP/IPv6/TCP 生命周期决定最终体验是否接近 Surge。

从工程视角看，Blaze 正在从“能代理”走向“能透明接管”。后续最重要的工作不是继续堆 UI，而是把 TCP、DNS、UDP、IPv6、路由绕过和可观测性做扎实。
