
find_package(Pandoc REQUIRED)

add_man_page(brickrun.1
    SECTION 1
    HEADER "User's Manual"
    FOOTER ${PROJECT_VERSION}
    brickrun.rst)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/brickrun.1 DESTINATION ${CMAKE_INSTALL_DOCDIR}/man)

add_custom_target(doc ALL DEPENDS brickrun.1)
