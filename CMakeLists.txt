cmake_minimum_required(VERSION 3.16)

project(JNetApplet VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick DBus)
find_package(Dtk6 REQUIRED COMPONENTS Core)
find_package(DDEShell REQUIRED)

# 插件 ID
set(PLUGIN_ID "space.jokul.JNetApplet")

add_library(space.jokul.JNetApplet SHARED
    networkmonitorapplet.h
    networkmonitorapplet.cpp
)

set_target_properties(space.jokul.JNetApplet PROPERTIES PREFIX "")

target_include_directories(space.jokul.JNetApplet PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    /usr/include/dde-shell
)

target_link_libraries(space.jokul.JNetApplet PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::DBus
    Dtk6::Core
    Dde::Shell
)

# 安装到dde-shell插件目录
install(TARGETS space.jokul.JNetApplet DESTINATION /usr/lib/x86_64-linux-gnu/dde-shell)
install(FILES package/metadata.json DESTINATION /usr/share/dde-shell/${PLUGIN_ID})
install(FILES package/networkview.qml DESTINATION /usr/share/dde-shell/${PLUGIN_ID})