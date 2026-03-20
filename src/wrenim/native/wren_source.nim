import std/os

const
  vendorDir = parentDir(currentSourcePath()) / "vendor" / "wren"
  wrenIncludeDir* = vendorDir / "include"
  wrenVmDir* = vendorDir / "vm"
  wrenOptionalDir* = vendorDir / "optional"

const wrenVersion* = "0.4.0+99d2f0b8"
