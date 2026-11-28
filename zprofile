amiga16() {
  path=(/opt/amiga-16.2/bin ${path:#/opt/amiga-[0-9]*/bin})
  export PATH
  rehash
}

export PATH=$PATH:/opt/amiga-ppc-16.2/bin

# Optional default on new shells:
amiga16

