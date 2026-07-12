cmake_minimum_required(VERSION 3.16)

project(JNetApplet)

find_package(DDEShell REQUIRED NO_MODULE)

ds_install_package(PACKAGE space.jokul.JNetApplet)
