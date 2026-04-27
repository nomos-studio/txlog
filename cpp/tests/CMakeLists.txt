# SPDX-License-Identifier: BSL-1.0

add_executable(txlog-tests
    test_txlog.cpp
)

target_link_libraries(txlog-tests
    PRIVATE txlog::txlog
            Catch2::Catch2WithMain
)

set_target_properties(txlog-tests PROPERTIES
    CXX_STANDARD          20
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS        OFF
)

include(CTest)
include(Catch)
catch_discover_tests(txlog-tests)
