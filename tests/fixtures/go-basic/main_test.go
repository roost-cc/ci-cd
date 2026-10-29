package main

import "testing"

func TestAdd(t *testing.T) {
	if Add(2, 2) != 4 {
		t.Fatal("expected 4")
	}
}
