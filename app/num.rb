# frozen_string_literal: true

# 跨平台数值工具——**已迁移到框架实现**（FRICTION-2.md G-11）。
#
# 从前这里有一份 `idiv` / `round_to` / `integral?` / `finite?` 的手写实现，
# 与 citrine-market-terminal 里那份同构——"每个应用都要写一遍"正是这条摩擦的论据。
# 现在框架提供 `Citrine::Num`（并带 `rake parity` 做 CRuby/Opal 逐字节比对），
# 本文件只保留常量别名，让调用点继续用短名字。
require "citrine"

module Sheets
  Num = Citrine::Num
end
