Vagrant.configure("2") do |c|

  c.vm.define "qmail" do |qmail|
    qmail.vm.box = "bento/rockylinux-9.6"
    qmail.vm.network "public_network", bridge: "en0: Wi-Fi"
    qmail.vm.synced_folder "./qmail", "/home/vagrant/qmail", create: true

    qmail.vm.provider "virtualbox" do |qmailb|
      qmailb.gui = false
      qmailb.memory = "2048"
    end
    
    qmail.vm.provision "shell", name: "setup", inline: <<-SHELL
      dnf update -y
      dnf install -y telnet
      pear install --alldeps Mail
      pear install Mail_Mime
      pear install Mail_mimeDecode
      ip route del default via 10.0.2.2 || true
      hostnamectl set-hostname test-qmail.julianmorley.ca
    SHELL

    qmail.vm.provision "shell", name: "setup qmail", path: "./install.sh"

  end

end
