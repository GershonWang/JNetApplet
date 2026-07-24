cmake_minimum_required(VERSION 3.16)

project(JNetApplet VERSION 1.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick DBus Network LinguistTools Test)
find_package(Dtk6 REQUIRED COMPONENTS Core)
find_package(DDEShell REQUIRED)

# 插件 ID
set(PLUGIN_ID "space.jokul.JNetApplet")

add_library(space.jokul.JNetApplet SHARED
    src/networkmonitorapplet.h
    src/networkmonitorapplet.cpp
)

set_target_properties(space.jokul.JNetApplet PROPERTIES PREFIX "")

# 将 project(VERSION) 暴露为编译宏，供 C++ version() 兜底使用
target_compile_definitions(space.jokul.JNetApplet PRIVATE PROJECT_VERSION="${PROJECT_VERSION}")

# 翻译文件：编译 .ts -> .qm，安装到插件目录的 translations/ 子目录
# 设计原因：QML 中 qsTr() 源串为英文，中文翻译通过 .qm 文件在运行时加载
set(TS_FILES ${CMAKE_CURRENT_SOURCE_DIR}/translations/jnetapplet_zh_CN.ts)
qt_add_translation(QM_FILES ${TS_FILES})
# 翻译文件安装路径，暴露为编译宏供 C++ 加载
target_compile_definitions(space.jokul.JNetApplet PRIVATE
    TRANSLATIONS_DIR="/usr/share/dde-shell/${PLUGIN_ID}/translations"
)
# 确保 .qm 在构建时生成（qt_add_translation 默认仅 install 时触发）
add_custom_target(translations ALL DEPENDS ${QM_FILES})

# 头文件搜索路径指向 src/，使 #include "networkmonitorapplet.h" 可被外部解析
target_include_directories(space.jokul.JNetApplet PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    /usr/include/dde-shell
)

target_link_libraries(space.jokul.JNetApplet PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::DBus
    Qt6::Network
    Dtk6::Core
    Dde::Shell
)

# 安装到dde-shell插件目录
install(TARGETS space.jokul.JNetApplet DESTINATION /usr/lib/x86_64-linux-gnu/dde-shell)

# 由模板生成 metadata.json，版本号从 project() 取，避免多处手动维护
# 设计原因：版本号唯一源为 CMakeLists.txt 顶部的 project(... VERSION)，
# configure_file 在构建目录生成最终 metadata.json，install 安装生成文件
configure_file(package/metadata.json.in ${CMAKE_CURRENT_BINARY_DIR}/metadata.json @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/metadata.json DESTINATION /usr/share/dde-shell/${PLUGIN_ID})
install(FILES package/networkview.qml DESTINATION /usr/share/dde-shell/${PLUGIN_ID})

# 安装 components 子目录下所有 QML 组件
# 设计原因：拆分出的子组件需随主 QML 一起安装到 dde-shell 插件目录，
# 否则 networkview.qml 的 import "components" 在运行时找不到类型
install(DIRECTORY package/components DESTINATION /usr/share/dde-shell/${PLUGIN_ID})

# 安装编译后的翻译文件
install(FILES ${QM_FILES} DESTINATION /usr/share/dde-shell/${PLUGIN_ID}/translations)

# ---- 单元测试 ----
# 直接编译源文件到测试可执行文件，避免共享库依赖问题
enable_testing()
add_executable(tst_networkmonitorapplet
    tests/tst_networkmonitorapplet.cpp
    src/networkmonitorapplet.cpp
    src/networkmonitorapplet.h
)
target_link_libraries(tst_networkmonitorapplet PRIVATE
    Qt6::Test
    Qt6::Core
    Qt6::Quick
    Qt6::DBus
    Qt6::Network
    Dtk6::Core
    Dde::Shell
)
target_include_directories(tst_networkmonitorapplet PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    /usr/include/dde-shell
)
target_compile_definitions(tst_networkmonitorapplet PRIVATE
    PROJECT_VERSION="${PROJECT_VERSION}"
    TRANSLATIONS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/translations"
)
add_test(NAME tst_networkmonitorapplet COMMAND tst_networkmonitorapplet)