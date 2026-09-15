# frozen_string_literal: true

# Citrine Sheets —— 任务入口（零依赖：只用 Ruby 标准库 + opal + node）
#
#   rake test      CRuby 内核单测（公式解析 / 求值 / 函数 / 工作簿 / 依赖图）
#   rake build     编译 app/sheets.rb → app/sheets.js
#   rake stubs     build + Node DOM 桩验收（77 项键盘与编辑链路断言）
#   rake parity    CRuby 与 Opal 两侧内核输出逐字节比对
#   rake check     test + stubs + parity（提交前跑）
#   rake dev       启动开发服务器（热刷新）
require "rake/testtask"

ROOT = File.expand_path(__dir__)
APP = File.join(ROOT, "app")
# citrine 框架位置：与本站同级目录，或用 CITRINE_ROOT 指定
CITRINE_ROOT = ENV["CITRINE_ROOT"] || File.expand_path("../citrine", ROOT)
CITRINE_LIB = File.join(CITRINE_ROOT, "lib")

OPAL = ENV["OPAL"] || "opal"
TMP = ENV["TMPDIR"] || "/tmp"

def check_citrine!
  return if File.directory?(CITRINE_LIB)

  abort <<~MSG
    找不到 citrine 框架：#{CITRINE_ROOT}
    请把本仓库与 citrine 仓库放在同一父目录下，或设置环境变量：
      export CITRINE_ROOT=/path/to/citrine
  MSG
end

Rake::TestTask.new do |t|
  t.libs << APP
  t.libs << CITRINE_LIB
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

desc "编译 app/sheets.rb → app/sheets.js"
task :build do
  check_citrine!
  Dir.chdir(APP) do
    sh "#{OPAL} -c -I#{CITRINE_LIB} -I. -o sheets.js sheets.rb"
  end
end

desc "编译并运行 Node DOM 桩验收（无需浏览器）"
task stubs: :build do
  sh "node test/sheets_stub_check.js"
end

NATIVE_ROOT = ENV["CITRINE_NATIVE_ROOT"] || File.expand_path("../citrine-native", ROOT)
NATIVE_LIB = File.join(NATIVE_ROOT, "lib")

desc "原生端口测试（CRuby + citrine-native 的 Memory 桩后端，无需窗口）"
Rake::TestTask.new("native:test") do |t|
  t.libs << APP
  t.libs << CITRINE_LIB
  t.libs << NATIVE_LIB
  t.test_files = FileList["native/test/*_test.rb"]
  t.warning = false
end

desc "CRuby 与 Opal 两侧内核输出一致性检查（跨平台语义回归防护）"
task :parity do
  check_citrine!
  cruby_out = File.join(TMP, "sheets_parity_cruby.txt")
  opal_out = File.join(TMP, "sheets_parity_opal.txt")
  opal_js = File.join(TMP, "sheets_parity.js")

  Dir.chdir(APP) do
    sh "ruby -I#{CITRINE_LIB} parity.rb > #{cruby_out}"
    sh "#{OPAL} -c -I#{CITRINE_LIB} -I. -o #{opal_js} parity.rb"
  end
  sh "node #{opal_js} > #{opal_out}"

  if File.read(cruby_out) == File.read(opal_out)
    puts "✅ CRuby 与 Opal 两侧输出逐字节一致（#{File.readlines(cruby_out).size} 行）"
  else
    sh "diff #{cruby_out} #{opal_out}"
    abort "❌ 两侧输出不一致（见上）"
  end
end

desc "提交前检查：单测 + 桩验收 + 跨平台一致性"
task check: %i[test stubs parity]

desc "启动 Citrine 开发服务器（热刷新；端口默认 4404）"
task :dev do
  check_citrine!
  require File.join(CITRINE_LIB, "citrine/dev_server")
  Citrine::DevServer.run!([APP, "-p", "4404"])
end

task default: :check
