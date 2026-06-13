package main

import "fmt"

func main() {
	b := new(true)
	fmt.Printf("%T %v\n", b, b)
}
