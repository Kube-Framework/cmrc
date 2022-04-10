#include <cmrc/cmrc.hpp>

#include <iostream>

CMRC_DECLARE(enoent);

int main() {
    auto fs = cmrc::enoent::get_filesystem();
    auto data = fs.open("hello.txt");
    return data.begin() == nullptr && data.end() == nullptr;
}
