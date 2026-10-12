# Board 用桌面层级的普通窗口实现，不用 WidgetKit 桌面小组件

「固定在桌面」有三种做法：桌面层级的窗口（像 Stickies）、始终置顶的浮动窗口、macOS 桌面小组件（WidgetKit）。

我们选**桌面层级的窗口**，并允许在菜单栏切换成始终置顶（Board Mode）。

## Considered Options

- **WidgetKit 小组件**：否决。小组件只能有限交互（不能直接编辑、展开 Detail、打开 Material），需要 App Group 和沙盒化的 extension，和自签名、不公证的分发方式（ADR-0004）配合风险大。
- **只做始终置顶**：否决为默认。一直盖在工作窗口上面；保留为可选的 Board Mode。

## Consequences

- 桌面层级窗口的点击、编辑、拖动需要真机核实（ARCHITECTURE §10）。
- 不需要任何系统权限。
