# Single-node Nomad agent (server + client) running tradera's docker VMs on
# the host docker daemon (socket mounted into the container). The data dir is
# passed with -data-dir and must be mounted at the SAME path on the host so the
# docker driver can bind-mount allocation directories into task containers.
bind_addr = "0.0.0.0"

advertise {
  http = "{{ GetInterfaceIP \"eth0\" }}"
  rpc  = "{{ GetInterfaceIP \"eth0\" }}"
  serf = "{{ GetInterfaceIP \"eth0\" }}"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled           = true
  cpu_total_compute = 20000
}

plugin "docker" {
  config {
    volumes {
      enabled = true
    }
    allow_privileged = false
  }
}

# Without a raw_exec/exec driver the client only runs docker tasks.
disable_update_check = true
