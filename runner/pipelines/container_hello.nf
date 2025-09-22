nextflow.enable.dsl=2

process HELLO_IN_CONTAINER {
  container 'ubuntu:22.04'
  containerOptions '--user 0:0'

  // Нужные утилиты для .command.run / nxf_trace
  beforeScript '''
    set -euo pipefail
    apt-get update
    apt-get install -y --no-install-recommends procps coreutils
    rm -rf /var/lib/apt/lists/*
  '''

  output:
    path 'hello.txt'

  script:
  """
  set -euo pipefail
  echo "Hello from Docker container!" > hello.txt
  """
}

workflow {
  HELLO_IN_CONTAINER()
}
