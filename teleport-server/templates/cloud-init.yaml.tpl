#cloud-config

runcmd:
  - [ systemctl, enable, teleport.service ]
  - [ certbot, certonly, --server, "${acme_server}", -n, --agree-tos, --email, ${letsencrypt_email}, --dns-route53, -d, ${teleport_domain_name}, --deploy-hook, /usr/local/bin/teleport_enable_tls.sh ]
  - [ systemctl, start, teleport.service ]
  - [ tar, xvf, /root/AgentDependencies.tar.gz, -C, /tmp/ ]
  - [ python3 , /root/awslogs-agent-setup.py, -n, --region, ${teleport_dynamodb_region}, --dependency-path, /tmp/AgentDependencies, -c, /etc/awslogs/awslogs.conf ]

write_files:
- content: |
    ---
    # By default, this file should be stored in /etc/teleport.yaml

    # This section of the configuration file applies to all teleport
    # services.
    teleport:
      # nodename allows to assign an alternative name this node can be reached by.
      # by default it's equal to hostname
      nodename: ${teleport_domain_name}

      # Data directory where Teleport keeps its data, like keys/users for
      # authentication (if using the default BoltDB back-end)
      data_dir: /var/lib/teleport

      # Teleport throttles all connections to avoid abuse. These settings allow
      # you to adjust the default limits
      connection_limits:
        max_connections: 1000
        max_users: 250

      # Logging configuration. Possible output values are 'stdout', 'stderr' and
      # 'syslog'. Possible severity values are INFO, WARN and ERROR (default).
      log:
        output: ${teleport_log_output}
        severity: ${teleport_log_severity}

      storage:
        type: dynamodb
        region: ${teleport_dynamodb_region}
        table_name: ${teleport_dynamodb_table}
        audit_events_uri: ["dynamodb://${teleport_dynamodb_table}_events", "file:///var/lib/teleport/audit/events"]
        audit_sessions_uri: "s3://${recorded_sessions_bucket_name}/teleport.events"

    # This section configures the 'auth service':
    auth_service:
      # Turns 'auth' role on. Default is 'yes'
      enabled: yes

      authentication:
        # default authentication type. possible values are 'local', 'oidc' and 'saml'
        # only local authentication (Teleport's own user DB) is supported in the open
        # source version
        type: local
        # second_factor can be off, otp, or u2f
        second_factor: otp

      # IP and the port to bind to. Other Teleport nodes will be connecting to
      # this port (AKA "Auth API" or "Cluster API") to validate client
      # certificates
      listen_addr: 0.0.0.0:3025

      # Pre-defined tokens for adding new nodes to a cluster. Each token specifies
      # the role a new node will be allowed to assume. The more secure way to
      # add nodes is to use `ttl node add --ttl` command to generate auto-expiring
      # tokens.
      #
      # We recommend to use tools like `pwgen` to generate sufficiently random
      # tokens of 32+ byte length.
      tokens: ${teleport_auth_tokens}

      # Optional "cluster name" is needed when configuring trust between multiple
      # auth servers. A cluster name is used as part of a signature in certificates
      # generated by this CA.
      #
      # By default an automatically generated GUID is used.
      #
      # IMPORTANT: if you change cluster_name, it will invalidate all generated
      # certificates and keys (may need to wipe out /var/lib/teleport directory)
      cluster_name: ${teleport_cluster_name}

      # Optional setting for configuring session recording. Possible values are:
      #    "node"  : sessions will be recorded on the node level  (the default)
      #    "proxy" : recording on the proxy level, see "recording proxy mode" in "Audit Log" section
      #    "off"   : session recording is turned off
      session_recording: "${teleport_session_recording}"

    # This section configures the 'node service':
    ssh_service:
      # Turns 'ssh' role on. Default is 'yes'
      enabled: yes

      # IP and the port for SSH service to bind to.
      listen_addr: 0.0.0.0:3022

      # See explanation of labels in "Labeling Nodes" section below
      labels:
        function: teleport-server
        aws_region: ${teleport_dynamodb_region}
        project: ${project}
        environment: ${environment}
        instance_type: ${instance_type}

      # List of the commands to periodically execute. Their output will be used as node labels.
      commands:
        - name: teleport_version
          command: ['/bin/sh', '-c', '/usr/local/bin/teleport version | cut -d " " -f2']
          period: 24h0m0s

    # This section configures the 'proxy servie'
    proxy_service:
      # Turns 'proxy' role on. Default is 'yes'
      enabled: yes

      # SSH forwarding/proxy address. Command line (CLI) clients always begin their
      # SSH sessions by connecting to this port
      listen_addr: 0.0.0.0:3023

      # Reverse tunnel listening address. An auth server (CA) can establish an
      # outbound (from behind the firewall) connection to this address.
      # This will allow users of the outside CA to connect to behind-the-firewall
      # nodes.
      tunnel_listen_addr: 0.0.0.0:3024

      # The HTTPS listen address to serve the Web UI and also to authenticate the
      # command line (CLI) users via password+HOTP
      web_listen_addr: 0.0.0.0:443

      # TLS certificate for the HTTPS connection. Configuring these properly is
      # critical for Teleport security.
      #https_key_file: /etc/letsencrypt/live/${teleport_domain_name}/privkey.pem
      #https_cert_file: /etc/letsencrypt/live/${teleport_domain_name}/fullchain.pem
  path: /etc/teleport.yaml
- content: |
    [Unit]
    Description=Teleport SSH Service
    After=network.target

    [Service]
    Type=simple
    Restart=on-failure
    ExecStart=/usr/local/bin/teleport start -c /etc/teleport.yaml --pid-file=/var/run/teleport.pid
    ExecReload=/bin/kill -HUP $MAINPID
    PIDFile=/var/run/teleport.pid
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
  path: /etc/systemd/system/teleport.service
- content: |
    #!/bin/sh
    # Enable TLS certificate in teleport if not already enabled
    sed -i '/https_key_file:/s/^\(\s*\)#/\1/g' /etc/teleport.yaml
    sed -i '/https_cert_file:/s/^\(\s*\)#/\1/g' /etc/teleport.yaml
    # Reload teleport
    systemctl restart teleport.service
  path: /usr/local/bin/teleport_enable_tls.sh
  permissions: '0755'
- content: |
    [general]
    state_file = /var/awslogs/state/agent-state
    [teleport_audit_log]
    datetime_format = %b %d %H:%M:%S
    file = /var/lib/teleport/audit/events/*.log
    buffer_duration = 5000
    log_stream_name = {instance_id}
    initial_position = start_of_file
    log_group_name = teleport_audit_log
    [teleport_log]
    datetime_format = %b %d %H:%M:%S
    file = /var/log/teleport.log
    buffer_duration = 5000
    log_stream_name = {instance_id}
    initial_position = start_of_file
    log_group_name = teleport_log
  path: /etc/awslogs/awslogs.conf
- content: |
    :programname, isequal, "teleport" /var/log/teleport.log

    & stop
  path: /etc/rsyslog.d/teleport.conf
