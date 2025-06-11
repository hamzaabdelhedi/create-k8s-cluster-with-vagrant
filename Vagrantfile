# -*- mode: ruby -*-
# vi: set ft=ruby :

# Configuration
NUM_NODES = ENV['NODES'] ? ENV['NODES'].to_i : 2
NODE_MEMORY = ENV['NODE_MEMORY'] || "2048"
NODE_CPUS = ENV['NODE_CPUS'] || "2"
KUBERNETES_VERSION = ENV['K8S_VERSION'] || "1.28.0"

# Validate node count
if NUM_NODES < 2 || NUM_NODES > 4
  puts "Error: Number of nodes must be between 2 and 4"
  exit 1
end

puts "Setting up Kubernetes cluster with #{NUM_NODES} nodes"

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.box_version = "20230607.0.0"

  # Master node
  config.vm.define "k8s-master" do |master|
    master.vm.hostname = "k8s-master"
    master.vm.network "private_network", ip: "192.168.56.10"
    
    master.vm.provider "virtualbox" do |vb|
      vb.memory = NODE_MEMORY
      vb.cpus = NODE_CPUS
      vb.name = "k8s-master"
    end

    master.vm.provision "shell", inline: <<-SHELL

      echo "[Step 1] Update packages"
      apt-get update
      apt-get upgrade -y

      echo "[Step 2] Enable cgroups v2"
      sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 /' /etc/default/grub
      sudo update-grub

      echo "[Step 3] Install required dependencies"
      sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common


      echo "[Step 4] Add Docker’s GPG key and repo"
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

      echo "[Step 5] Install Docker Engine and containerd"
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io

      echo "[Step 6] Configure containerd for Kubernetes"
      sudo mkdir -p /etc/containerd
      containerd config default | sudo tee /etc/containerd/config.toml

      # Ensure Systemd cgroup driver is used (required by kubelet)
      sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

      sudo systemctl restart containerd
      sudo systemctl enable containerd

      echo "[Step 7] Add user to docker group (optional)"
      sudo usermod -aG docker $USER

      # Disable swap
      swapoff -a
      sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

      # Install kubeadm, kubelet, and kubectl
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
      #curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
      #echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
      apt-get update
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      # Configure kubelet
      echo "KUBELET_EXTRA_ARGS=--node-ip=192.168.56.10" > /etc/default/kubelet
      systemctl restart kubelet

      # Enable required kernel modules
      modprobe br_netfilter
      echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables
      echo '1' > /proc/sys/net/ipv4/ip_forward

      # Make kernel settings persistent
      cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

      sysctl --system
      docker version
      kubectl version
      crictl info
    SHELL

    # Initialize Kubernetes cluster
    master.vm.provision "shell", inline: <<-SHELL
      # Check if cluster is already initialized
      if [ ! -f /etc/kubernetes/admin.conf ]; then
        echo "Initializing Kubernetes cluster..."
        kubeadm init --apiserver-advertise-address=192.168.56.10 --pod-network-cidr=10.244.0.0/16 --kubernetes-version=#{KUBERNETES_VERSION}
        
        # Set up kubectl for vagrant user
        mkdir -p /home/vagrant/.kube
        cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
        chown vagrant:vagrant /home/vagrant/.kube/config
        
        # Set up kubectl for root
        export KUBECONFIG=/etc/kubernetes/admin.conf
        
        # Copy kubeconfig to host machine with correct server address
        mkdir -p /vagrant/.kube
        sed 's/192.168.56.10:6443/192.168.56.10:6443/g' /etc/kubernetes/admin.conf > /vagrant/.kube/config
        chmod 644 /vagrant/.kube/config
        
        # Install Flannel network plugin
        kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
        
        # Generate join command and save it
        kubeadm token create --print-join-command > /vagrant/kubeadm-join.sh
        chmod +x /vagrant/kubeadm-join.sh
        
        echo "Master node initialized successfully!"
      else
        echo "Cluster already initialized, regenerating join token..."
        kubeadm token create --print-join-command > /vagrant/kubeadm-join.sh
        chmod +x /vagrant/kubeadm-join.sh
      fi
    SHELL
  end

  # Worker nodes
  (1..NUM_NODES-1).each do |i|
    config.vm.define "k8s-worker#{i}" do |worker|
      worker.vm.hostname = "k8s-worker#{i}"
      worker.vm.network "private_network", ip: "192.168.56.#{10+i}"
      
      worker.vm.provider "virtualbox" do |vb|
        vb.memory = NODE_MEMORY
        vb.cpus = NODE_CPUS
        vb.name = "k8s-worker#{i}"
      end

      worker.vm.provision "shell", inline: <<-SHELL
          

        echo "[Step 1] Update packages"
        apt-get update
        apt-get upgrade -y

        echo "[Step 2] Enable cgroups v2"
        sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1 /' /etc/default/grub
        sudo update-grub

        echo "[Step 3] Install required dependencies"
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common


        echo "[Step 4] Add Docker’s GPG key and repo"
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        echo "[Step 5] Install Docker Engine and containerd"
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io

        echo "[Step 6] Configure containerd for Kubernetes"
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml

        # Ensure Systemd cgroup driver is used (required by kubelet)
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

        sudo systemctl restart containerd
        sudo systemctl enable containerd

        echo "[Step 7] Add user to docker group (optional)"
        sudo usermod -aG docker $USER

        # Disable swap
        swapoff -a
        sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

        # Install kubeadm, kubelet, and kubectl
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
        #curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
        #echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update
        apt-get install -y kubelet kubeadm kubectl
        apt-mark hold kubelet kubeadm kubectl

        # Configure kubelet
        echo "KUBELET_EXTRA_ARGS=--node-ip=192.168.56.10" > /etc/default/kubelet
        systemctl restart kubelet

        # Enable required kernel modules
        modprobe br_netfilter
        echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables
        echo '1' > /proc/sys/net/ipv4/ip_forward

      # Make kernel settings persistent
        cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

        sysctl --system
        docker version
        kubectl version
        crictl info  


      SHELL

      # Join the cluster
      worker.vm.provision "shell", inline: <<-SHELL
        # Wait for join script to be available
        while [ ! -f /vagrant/kubeadm-join.sh ]; do
          echo "Waiting for join script from master..."
          sleep 10
        done
        
        # Check if node is already part of cluster
        if ! systemctl is-active --quiet kubelet || ! kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get nodes 2>/dev/null | grep -q k8s-worker#{i}; then
          echo "Joining the cluster..."
          bash /vagrant/kubeadm-join.sh
          echo "Worker#{i} joined the cluster successfully!"
        else
          echo "Worker#{i} is already part of the cluster"
        fi
      SHELL
    end
  end
end