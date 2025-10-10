#include "include/encoding.h"
#include <functional>
#include <iostream>

void encode(int a, int b){

}

void encode(int a, int *b){

}

int main() {
  auto f = std::bind(is_equal, std::placeholders::_1, 10); // 绑定第二个参数为10
  std::cout << f(5) << std::endl; // 等价于 is_equal(5, 10)，输出 0（false）
  std::cout << f(11) << std::endl; // 等价于 is_equal(10, 10)，输出 1（true）
}
