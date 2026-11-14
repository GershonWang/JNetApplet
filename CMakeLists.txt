cmake_minimum_required(VERSION 3.16)

project(JNetApplet VERSION 2.3.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# DBus 组件已移除：src/ 未使用任何 QtDBus 符号，且上游 DDEShellConfig.cmake
# 的实际依赖链只有 Dtk6Core/Dtk6Gui 与 Qt6 Qml/Quick，不涉及 DBus
#（已本机读取 DDEShellConfig.cmake 确认，不再保留"无法确认"的猜测式依赖）
# 是否构建 dde-shell 插件本体（默认 ON）。
# 设计原因：CI 需要在没有 deepin 生态的环境里运行单元测试，而插件本体依赖
# Dtk6::Core 与 Dde::Shell（仅 deepin 仓库提供）。关掉本开关时只构建
# jnetcore（纯逻辑库）与其测试，任何装了 qt6-base-dev 的机器都能跑：
#     cmake -B build -DJNET_BUILD_PLUGIN=OFF && cmake --build build --target tst_core
option(JNET_BUILD_PLUGIN "构建 dde-shell 插件本体（需要 Dtk6 与 DDEShell）" ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick Network LinguistTools)
# Test 仅用于单元测试目标，非主插件依赖；将其设为可选，
# 避免未安装 Qt6 Test 开发包的环境构建主插件时失败
find_package(Qt6 OPTIONAL_COMPONENTS Test)
if(JNET_BUILD_PLUGIN)
    find_package(Dtk6 REQUIRED COMPONENTS Core)
    find_package(DDEShell REQUIRED)
endif()

# 插件 ID
set(PLUGIN_ID "space.jokul.JNetApplet")

# ---- 纯逻辑核心库 ----
# 设计原因：NetworkMonitorApplet 继承 DApplet，编译它必须链接 Dtk6::Core 与
# Dde::Shell，而这两者只在 deepin 仓库提供——GitHub runner 上装不了，
# 导致单元测试永远进不了 CI，只能靠真机手工验证。
# 把"纯字符串/JSON 进、结构化数据出"的逻辑抽成只依赖 Qt6::Core 的库后，
# 任何装了 qt6-base-dev 的机器都能编译并运行它（见 tests/core/）。
# 需要文件系统、子进程、DApplet 生命周期的部分刻意不抽——那会变成假抽象。
add_library(jnetcore STATIC
    src/core/netparsers.h
    src/core/netparsers.cpp
    src/core/netstate.h
    src/core/netstate.cpp
    src/core/trafficlog.h
    src/core/trafficlog.cpp
)
# 位置无关代码：被主插件 SHARED 库静态链接
set_target_properties(jnetcore PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_link_libraries(jnetcore PUBLIC Qt6::Core)
target_include_directories(jnetcore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)

if(JNET_BUILD_PLUGIN)
add_library(space.jokul.JNetApplet SHARED
    src/networkmonitorapplet.h
    src/networkmonitorapplet.cpp
)

set_target_properties(space.jokul.JNetApplet PROPERTIES PREFIX "")

# 将 project(VERSION) 暴露为编译宏，供 C++ version() 兜底使用
target_compile_definitions(space.jokul.JNetApplet PRIVATE PROJECT_VERSION="${PROJECT_VERSION}")

# ---- 安装路径：统一取自 dde-shell 导出的变量 ----
# 设计原因：DDEShellConfig.cmake 会导出 DDE_SHELL_PACKAGE_INSTALL_DIR（默认
# /usr/share/dde-shell）与 DDE_SHELL_PLUGIN_INSTALL_DIR（默认
# /usr/lib/<triplet>/dde-shell）。此前本项目把这些路径写成绝对 DESTINATION，
# 导致 CMAKE_INSTALL_PREFIX 与自定义 dde-shell 前缀完全失效：
# 本机 CMakeCache 的 prefix 是 /usr/local，而 install_manifest 仍写死 /usr。
# 改用导出变量后，安装位置由 dde-shell 自身决定，跨发行版/自定义前缀都能对上。
# 兜底：极老版本 dde-shell 可能未导出这些变量，此时按 GNUInstallDirs 推导
include(GNUInstallDirs)
if(NOT DEFINED DDE_SHELL_PACKAGE_INSTALL_DIR)
    set(DDE_SHELL_PACKAGE_INSTALL_DIR "${CMAKE_INSTALL_DATADIR}/dde-shell")
endif()
if(NOT DEFINED DDE_SHELL_PLUGIN_INSTALL_DIR)
    set(DDE_SHELL_PLUGIN_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}/dde-shell")
endif()
# 插件资源目录（metadata/QML/组件/翻译）的完整路径，供多处复用
set(PLUGIN_DATA_DIR "${DDE_SHELL_PACKAGE_INSTALL_DIR}/${PLUGIN_ID}")

# 翻译文件：编译 .ts -> .qm，安装到插件目录的 translations/ 子目录
# 设计原因：QML 中 qsTr() 源串为英文，中文翻译通过 .qm 文件在运行时加载
set(TS_FILES ${CMAKE_CURRENT_SOURCE_DIR}/translations/jnetapplet_zh_CN.ts)
qt_add_translation(QM_FILES ${TS_FILES})

# 翻译文件安装路径，暴露为编译宏供 C++ 在运行时加载 .qm
# 注意：C++ 必须与安装位置一致，故此处直接复用上面的 PLUGIN_DATA_DIR
target_compile_definitions(space.jokul.JNetApplet PRIVATE
    TRANSLATIONS_DIR="${PLUGIN_DATA_DIR}/translations"
)
# 确保 .qm 在构建时生成（qt_add_translation 默认仅 install 时触发）
add_custom_target(translations ALL DEPENDS ${QM_FILES})

# 头文件搜索路径只需指向 src/：dde-shell 的头文件由 Dde::Shell 目标自带
# （DDEShellTargets.cmake 已声明 INTERFACE_INCLUDE_DIRECTORIES），
# 原先额外硬编码的 /usr/include/dde-shell 在 dde-shell 装于其它前缀时会失效
target_include_directories(space.jokul.JNetApplet PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# 链接依赖
# 已核实 DDEShellConfig.cmake 的实际依赖链：只 find_dependency(Dtk6Core/Dtk6Gui)
# 与 find_package(Qt6 Qml Quick)，不涉及 DBus，故不再查找 DBus 组件
target_link_libraries(space.jokul.JNetApplet PRIVATE
    jnetcore
    Qt6::Core
    Qt6::Quick
    Qt6::Network
    Dtk6::Core
    Dde::Shell
)

# 安装插件动态库到 dde-shell 插件目录
install(TARGETS space.jokul.JNetApplet DESTINATION ${DDE_SHELL_PLUGIN_INSTALL_DIR})

# 由模板生成 metadata.json，版本号从 project() 取，避免多处手动维护
# 设计原因：版本号唯一源为 CMakeLists.txt 顶部的 project(... VERSION)，
# configure_file 在构建目录生成最终 metadata.json，install 安装生成文件
configure_file(package/metadata.json.in ${CMAKE_CURRENT_BINARY_DIR}/metadata.json @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/metadata.json DESTINATION ${PLUGIN_DATA_DIR})
install(FILES package/networkview.qml DESTINATION ${PLUGIN_DATA_DIR})

# 安装 components 子目录下所有 QML 组件
# 设计原因：拆分出的子组件需随主 QML 一起安装到 dde-shell 插件目录，
# 否则 networkview.qml 的 import "components" 在运行时找不到类型
install(DIRECTORY package/components DESTINATION ${PLUGIN_DATA_DIR})

# 安装编译后的翻译文件
install(FILES ${QM_FILES} DESTINATION ${PLUGIN_DATA_DIR}/translations)

endif()
# 打印最终安装位置，便于 install.sh 与用户核对（配置阶段即可见，不必等安装）
message(STATUS "JNetApplet 安装位置：插件 ${DDE_SHELL_PLUGIN_INSTALL_DIR}，资源 ${PLUGIN_DATA_DIR}")

# ---- 单元测试 ----
# 仅当 Qt6 Test 组件存在时才构建测试目标
# 设计原因：Test 为可选组件，未安装 Qt6 Test 开发包的环境仍应能正常构建主插件
if(TARGET Qt6::Test)
    # 直接编译源文件到测试可执行文件，避免共享库依赖问题
    enable_testing()
    # 插件集成测试需要 Dtk6/Dde::Shell，仅在构建插件时生成
    if(JNET_BUILD_PLUGIN)
    add_executable(tst_networkmonitorapplet
        tests/tst_networkmonitorapplet.cpp
        src/networkmonitorapplet.cpp
        src/networkmonitorapplet.h
    )
    # 与主插件保持一致：链接依赖与头文件路径完全对齐，
    # 头文件由 Dde::Shell 目标自带，不再硬编码 /usr/include/dde-shell
    target_link_libraries(tst_networkmonitorapplet PRIVATE
        jnetcore
        Qt6::Test
        Qt6::Core
        Qt6::Quick
        Qt6::Network
        Dtk6::Core
        Dde::Shell
    )
    target_include_directories(tst_networkmonitorapplet PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
    )
    target_compile_definitions(tst_networkmonitorapplet PRIVATE
        PROJECT_VERSION="${PROJECT_VERSION}"
        TRANSLATIONS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/translations"
    )
    add_test(NAME tst_networkmonitorapplet COMMAND tst_networkmonitorapplet)
    endif()

    # ---- 纯逻辑核心库测试：只依赖 Qt6::Core 与 Qt6::Test ----
    # 设计原因：上面那个目标编译 NetworkMonitorApplet（继承 DApplet），
    # 必须链接 Dtk6::Core 与 Dde::Shell，GitHub runner 上装不了，于是永远进不了 CI。
    # 这个目标只链接 qt6-base-dev 就够，**可在任意环境运行**（CI 即跑它）：
    #     cmake -B build && cmake --build build && ctest --output-on-failure
    add_executable(tst_core tests/core/tst_core.cpp)
    target_link_libraries(tst_core PRIVATE Qt6::Test Qt6::Core jnetcore)
    add_test(NAME tst_core COMMAND tst_core)
endif()