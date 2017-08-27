
find_package(Valac REQUIRED)
find_package(PkgConfig REQUIRED)

pkg_check_modules(BRICKRUN_DEPS REQUIRED
    glib-2.0
    gobject-2.0
    gio-2.0
    gio-unix-2.0
)

configure_file(version.vala.in version.vala @ONLY)

vala2c(BRICKRUN_C_FILES
    PACKAGES
        gio-2.0
        gio-unix-2.0
        posix
    TARGET_GLIB
        2.48
    SOURCE_FILES
        ${CMAKE_CURRENT_BINARY_DIR}/version.vala
        brickrun.vala
)

set(BRICKRUN_TARGET "brickrun")
add_executable(${BRICKRUN_TARGET} ${BRICKRUN_C_FILES})
target_compile_options(${BRICKRUN_TARGET} PRIVATE "-w")
target_include_directories(${BRICKRUN_TARGET} PRIVATE ${BRICKRUN_DEPS_INCLUDE_DIRS})
target_link_libraries(${BRICKRUN_TARGET} ${BRICKRUN_DEPS_LIBRARIES} ${SHARED_LIBRARY_TARGET})

install(TARGETS ${BRICKRUN_TARGET} RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
