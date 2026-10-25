#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

static std::mutex mtx;

int main()
{
    try {
        throw std::runtime_error("exception");
    } catch (const std::exception &e) {
        std::cout << "caught " << e.what() << std::endl;
    }

    std::thread t([] {
        std::lock_guard<std::mutex> lock(mtx);
        std::cout << "Hello from a ppc-amigaos-g++ thread" << std::endl;
    });
    t.join();
    return 0;
}
