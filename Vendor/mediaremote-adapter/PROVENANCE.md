# MediaRemoteAdapter（实验性系统级正在播放）

- 来源：https://github.com/ungive/mediaremote-adapter （BSD 3-Clause）
- 构建产物：Resources/MediaRemoteAdapter.fwk（x86_64+arm64 通用）
- 脚本：Resources/mediaremote-adapter.pl
- 重建：cmake .. -DCMAKE_BUILD_TYPE=Release && make（产物在 build/MediaRemoteAdapter.framework，改名为 .fwk 拷入 Resources）
- 原理：/usr/bin/perl 属苹果平台二进制（bundle id com.apple.perl5），
  mediaremoted 仅信任 com.apple.* 客户端；Perl 动态加载本框架读取
  系统正在播放并输出 JSON。 BSD-3 授权，归属原作者。
