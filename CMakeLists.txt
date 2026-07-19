cmake_minimum_required(VERSION 3.16)

project(JNetApplet VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick DBus Network)
find_package(Dtk6 REQUIRED COMPONENTS Core)
find_package(DDEShell REQUIRED)

# 插件 ID
set(PLUGIN_ID "space.jokul.JNetApplet")

add_library(space.jokul.JNetApplet SHARED
    src/networkmonitorapplet.h
    src/networkmonitorapplet.cpp
)

set_target_properties(space.jokul.JNetApplet PROPERTIES PREFIX "")

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