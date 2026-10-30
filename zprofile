amiga6() {
  path=(/opt/amiga-6.5.0b/bin ${path:#/opt/amiga-[0-9]*/bin})
  export PATH
  rehash
}

amiga13() {
  path=(/opt/amiga-13.4/bin ${path:#/opt/amiga-[0-9]*/bin})
  export PATH
  rehash
}

amiga16() {
  path=(/opt/amiga-16.2/bin ${path:#/opt/amiga-[0-9]*/bin})
  export PATH
  rehash
}

export PATH=$PATH:/opt/amiga-ppc-16.2/bin

# Optional default on new shells:
amiga16

