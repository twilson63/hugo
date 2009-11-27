require 'AWS'
require 'net/ssh'
require 'json'

class Hugo < Thor
  include Thor::Actions

  # map "-L" => :list

  @@amazon_access_key_id = ENV['AMAZON_ACCESS_KEY_ID']
  @@amazon_secret_access_key = ENV['AMAZON_SECRET_ACCESS_KEY']

  @@ec2_keyname = ENV['EC2_KEYNAME'].nil? ? 'ec2-keypair' : ENV['EC2_KEYNAME']
  @@ec2_keypair = ENV['EC2_KEYPAIR'].nil? ? "~/.ec2/ec2-keypair" : ENV['EC2_KEYPAIR']
  #@@ec2_ami_id = ENV['EC2_AMI_ID'].nil? ? 'ami-eefb1987' : ENV['EC2_AMI_ID']
  @@ec2_ami_id = ENV['EC2_AMI_ID'].nil? ? 'ami-1515f67c' : ENV['EC2_AMI_ID']

  @@hugo_config = YAML.load_file('config/hugo.yml')
  
  desc "build CUSTOMER APP", "Deploy Infrastructure for Customer and Application"
  def build(customer, app)
    deploy_rds(customer, app)
    deploy_elb(customer)
    create(customer)
    #deploy_web_base(customer, app)
    deploy_ec2(customer, app)
    puts "Infrastructure Deployed"
  end

  desc "drop CUSTOMER", "Drop Entire Customer Infrastructure"
  def drop(customer)
    terminate_instances(customer)
    delete_elb(customer)
    delete_rds(customer)
  end
  
  desc "add CUSTOMER APP [INSTANCES]", "add app instances"
  def add(customer, app, instances=1)
    create(customer, instances)
    deploy_ec2(customer, app)    
  end

  desc "create", "create ec2 server instance"
  def create(customer, instances=nil)
    @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)

    results = @ec2.run_instances(:image_id => @@ec2_ami_id, :key_name => @@ec2_keyname, 
      :max_count => instances || @@hugo_config['ec2']['default_instances'],
      :availability_zone => @@hugo_config['availability_zone'])
        
    results.instancesSet.item.each do |i|
      puts i.instanceId
      setup_ec2(i.instanceId)
      register_ec2(customer, i.instanceId)

    end
    # puts "Successfully creates web apps for #{customer}"
    #run "echo Successfully created Web App"
  end

  desc "setup_ec2 INSTANCE", "Setup EC2"
  def setup_ec2(instance)
    @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)

    loop do
      begin
        check_instance = @ec2.describe_instances(:instance_id => instance)
        # puts check_instance
        puts check_instance.reservationSet.item[0].instancesSet.item[0].instanceState.name
        if check_instance.reservationSet.item[0].instancesSet.item[0].instanceState.name == "running"
          @dnsName = check_instance.reservationSet.item[0].instancesSet.item[0].dnsName
          break
        end
      rescue Exception => ex
        puts ex.message
      end
      sleep 5
    end
    puts @dnsName
    sleep 20
    
    # Install Ruby, Git and Chef
    commands = []
    commands << 'sudo apt-get update -y'
    commands << 'sudo apt-get install ruby ruby1.8-dev libopenssl-ruby1.8 rdoc ri irb build-essential git-core xfsprogs -y'
    commands << 'wget http://rubyforge.org/frs/download.php/60718/rubygems-1.3.5.tgz && tar zxf rubygems-1.3.5.tgz'
    commands << 'cd rubygems-1.3.5 && sudo ruby setup.rb && sudo ln -sfv /usr/bin/gem1.8 /usr/bin/gem'
    commands << 'sudo gem update --system'
    commands << 'sudo gem install gemcutter --no-ri --no-rdoc'
    commands << 'sudo gem tumble'
    commands << 'sudo gem install chef ohai --no-ri --no-rdoc'
    commands << 'sudo gem source -a http://gems.github.com'
    commands << 'sudo gem install chef-deploy --no-ri --no-rdoc'
    commands << 'sudo gem install git --no-ri --no-rdoc'
    commands << "git clone #{@@hugo_config['git']} ~/hugo-repos"
    # Setup base role
    dna = { :run_list => ["role[web-base]"],
      :package_list => @@hugo_config['package_list'],
      :gem_list => @@hugo_config['gem_list'],
      :git => @@hugo_config['git'],
      :github => @@hugo_config['github'],
      :access_key => @@amazon_access_key_id,
      :secret_key => @@amazon_secret_access_key,
      :apache => @@hugo_config['apache']
      
    }

    commands << 'sudo chef-solo -c /home/ubuntu/hugo-repos/config/solo.rb -j /home/ubuntu/dna.json'
        
    ssh @dnsName, commands, dna
    
    
  end

  desc "register_ec2 ELB INSTANCE", "Register Instance for Load Balancer"
  def register_ec2(elb, instance)
    @elb = AWS::ELB::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    @elb.register_instances_with_load_balancer(
      :instances => [instance],
      :load_balancer_name => elb)
    puts "Registered - #{instance} to #{elb}"
  end
    
  
  desc "deploy_ec2 CUSTOMER APP", "deploy to uri"
  def deploy_ec2(customer, app)
    @app_config = YAML.load_file("config/#{app}.yml")
    db_uri = get_db_uri(customer)
    # get instances
    instances = get_instances(customer)
    puts instances.inspect
    instances.each do |i|
      uri = get_instance_uri(i.InstanceId)
      puts uri
            
      commands = []
      #commands << "git clone #{@@hugo_config['git']} ~/hugo-repos"
      commands << "cd hugo-repos && git pull"
      commands << 'sudo chef-solo -c /home/ubuntu/hugo-repos/config/solo.rb -j /home/ubuntu/dna.json'

      dna = { :run_list => @app_config['run_list'],
        :package_list => @app_config['package_list'],
        :gem_list => @app_config['gem_list'],
        :application => app, 
        :customer => customer,
        :database => { 
          :uri => db_uri, 
          :user => @@hugo_config['database']['master_username'], 
          :password => @@hugo_config['database']['master_user_password'] }, 
        :web => { :port => "8080", :ssl => "8443" }, 
        :git => @@hugo_config['git'],
        :github => @@hugo_config['github'],
        :access_key => @@amazon_access_key_id,
        :secret_key => @@amazon_secret_access_key,
        :app => @app_config['app'] || nil
      }

      ssh(uri, commands, dna)
  
    end
  end

  desc "terminate_instances INSTANCES", "Terminate an array of EC2 instances"
  def terminate_instances(customer)
    instances = get_instances(customer)

    instances.each do |i|
      @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
      @ec2.terminate_instances(:instance_id => i.InstanceId)
    end  
    puts "Terminated EC2 Instances"
  end

  desc "deploy_rds INSTANCE [DB]", "Deploy Amazon RDS Server"
  def deploy_rds(instance, db)
    puts "Building DB Server..."
    unless dns_name = get_db_uri(instance)
      # Call ec2 tool to deploy rds
      @rds = AWS::RDS::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
      # Check and see if db instance is already created
      # check_instance = @rds.describe_db_instances(:db_instance_identifier => instance)
      # unless check_instance.DescribeDBInstancesResult.DBInstances.DBInstance.DBInstanceStatus == "available"
        @rds.create_db_instance(
          :db_instance_identifier => instance,
          :allocated_storage => @@hugo_config['database']['default_size'],
          :db_instance_class => @@hugo_config['database']['db_instance_class'],
          :engine => "MySQL5.1",
          :master_username => @@hugo_config['database']['master_username'],
          :master_user_password => @@hugo_config['database']['master_user_password'],
          :db_name => db,
          :availability_zone => @@hugo_config['availability_zone'])
      # end
    
      #  :db_security_groups => [group]
      loop do
        check_instance = @rds.describe_db_instances(:db_instance_identifier => instance)
        if check_instance.DescribeDBInstancesResult.DBInstances.DBInstance.DBInstanceStatus == "available"
          break
        end
        sleep 5
      end
    
      dns_name = @rds.describe_db_instances(:db_instance_identifier => instance).DescribeDBInstancesResult.DBInstances.DBInstance.Endpoint.Address
    end
    puts dns_name
    dns_name
  end
  
  desc "delete_rds INSTANCE", "Delete Database RDS Instance"
  def delete_rds(instance)
    # Call ec2 tool to deploy rds
    @rds = AWS::RDS::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    @rds.delete_db_instance(:db_instance_identifier => instance, :skip_final_snapshot => true)
    puts "Deleted"
    
  end
  
  
  desc "deploy_elb INSTANCE", "Deploy Amazon Elastic Load Balancer"
  def deploy_elb(instance)
    puts "Building Load Balancer"
    @elb = AWS::ELB::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    # Need to check and see if the elb already exists
    #unless @elb.describe_load_balancers(:load_balancer_name => instance).DescribeLoadBalancerResult.DNSName
      lb = @elb.create_load_balancer(
        :load_balancer_name => instance,
        :listeners => [
          {:protocol => "HTTP", :load_balancer_port => "80", :instance_port => "8080"},
          {:protocol => "TCP", :load_balancer_port => "443", :instance_port => "8443"}],
        :availability_zones => [@@hugo_config['availability_zone']]
      )
    #end
    puts lb.CreateLoadBalancerResult.DNSName
    lb.CreateLoadBalancerResult.DNSName
  end
    
  desc "delete_elb INSTANCE", "Delete Load Balancer"
  def delete_elb(instance)
    @elb = AWS::ELB::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    @elb.delete_load_balancer(:load_balancer_name => instance)
    puts "DELETED"
    
  end

  desc "list_elb CUSTOMER", "list all of the customer elb instances"
  def list_elb(customer)
    begin
      elb = AWS::ELB::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
      puts elb.describe_load_balancers(:load_balancer_names => customer).inspect
    rescue AWS::Error => e
      puts e.message
    end
  end

  desc "list_rds CUSTOMER", "list all of the customer rds instances"
  def list_rds(customer)
    begin
      rds = AWS::RDS::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
      puts rds.describe_db_instances(:db_instance_identifier => customer).inspect
    rescue AWS::Error => e
      puts e.message
    end
  end  
  
  desc "deploy_jasper [INSTANCE]", "Deploy Jasper Server"
  def deploy_jasper(instance=nil)
    @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)

    if instance
      check_instance = @ec2.describe_instances(:instance_id => instance)
      @dnsName = check_instance.reservationSet.item[0].instancesSet.item[0].dnsName
      
    else

      results = @ec2.run_instances(:image_id => @@ec2_ami_id, :key_name => @@ec2_keyname, 
        :max_count => 1,
        :availability_zone => @@hugo_config['availability_zone'])
      puts results.inspect
      instance = results.instancesSet.item[0].instanceId
      loop do
        begin
          check_instance = @ec2.describe_instances(:instance_id => instance)
          # puts check_instance
          puts check_instance.reservationSet.item[0].instancesSet.item[0].instanceState.name
          if check_instance.reservationSet.item[0].instancesSet.item[0].instanceState.name == "running"
            @dnsName = check_instance.reservationSet.item[0].instancesSet.item[0].dnsName
            break
          end
        rescue Exception => ex
          puts ex.message
        end
        sleep 5
      end
      puts @dnsName
      sleep 20
      
    end
    
    setup_ec2(instance)
    
    dna = { :run_list => ["role[jasper]"] }
    commands = []
    commands << "git clone #{@@hugo_config['git']} ~/hugo-repos"
    commands << "cd hugo-repos && git pull"
    commands << 'sudo chef-solo -c /home/ubuntu/hugo-repos/config/solo.rb -j /home/ubuntu/dna.json'
    ssh(@dnsName, commands, dna)   
  end
  
private

  def get_db_uri(customer)
    # Need to get rds uri
    # db_uri
    @rds = AWS::RDS::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    rds_info = @rds.describe_db_instances(:db_instance_identifier => customer)
    rds_info.DescribeDBInstancesResult.DBInstances.DBInstance.Endpoint.Address
  rescue
    nil  
  end
  
  def get_instances(customer)
    result = nil
    @elb = AWS::ELB::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    @elb.describe_load_balancers().DescribeLoadBalancersResult.LoadBalancerDescriptions.member.each do |m|
      result = m.Instances.member if m.LoadBalancerName == customer
    end
    puts result
    result
  rescue
    nil
  end
  
  def get_instance_uri(instance)
    
    @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
    info = @ec2.describe_instances(:instance_id => instance)

    info.reservationSet.item[0].instancesSet.item[0].dnsName
    
  end
  
  def ssh(uri, commands, dna = nil)
    Net::SSH.start(uri, "ubuntu", :keys => @@ec2_keypair) do |ssh|
      if dna
        ssh.exec!("echo \"#{dna.to_json.gsub('"','\"')}\" > ~/dna.json")
      end
      commands.each do |cmd|
        puts ssh.exec!(cmd)
      end
      
    end
    
  end
  
  
  ### Build Infrastructure
  # hugo.yaml
  # database:
  #  master_user: jackdog
  #  master_password: bark1byte
  #  initial_size: 5
  # web-app:
  #  default-instances: 2
  
  
  # def deploy_standard(customer, application)
    # deploy_rds customer application 
    # deploy_elb customer
    # create_ec2 customer 
    # deploy_ec2 customer 
    # puts elb dns
  # end
  
  # deploy_jasper

  # desc "install APP_NAME", "install one of the available apps"
  # method_options :force => :boolean, :alias => :string
  # def install(name)
  #   user_alias = options[:alias]
  #   if options.force?
  #    # do something
  #   end
  #   # other code
  # end
  #
  # desc "list [SEARCH]", "list all of the available apps, limited by SEARCH"
  # def list(search="")
  #   run "echo Hello World"
  # end
  
  # desc "deploy_web_base CUSTOMER APP", "deploy web-base role to web servers"
  # def deploy_web_base(customer, app)
  #   instances = get_instances(customer)    
  #   instances.each do |i|
  # 
  #     @ec2 = AWS::EC2::Base.new(:access_key_id => @@amazon_access_key_id, :secret_access_key => @@amazon_secret_access_key)
  # 
  #     puts "instance: #{i.InstanceId}"
  #     info = @ec2.describe_instances(:instance_id => i.InstanceId)
  #     puts "info: #{info}"
  #     uri = info.reservationSet.item[0].instancesSet.item[0].dnsName
  #     puts "uri: #{uri}"
  # 
  #     Net::SSH.start(uri, "ubuntu", :keys => @@ec2_keypair) do |ssh|
  #       puts ssh.exec!("git clone #{@@hugo_config['git']} ~/hugo-repos")
  #       puts ssh.exec!("cd hugo-repos && git pull")
  #       dna = { :run_list => "role[web-base]", :package_list => @@hugo_config['package_list'], :gem_list => @@hugo_config['gem_list'] }
  #       puts ssh.exec!("echo \"#{dna.to_json.gsub('"','\"')}\" > ~/hugo-repos/dna.json")
  #       puts ssh.exec!('sudo chef-solo -c /home/ubuntu/hugo-repos/config/solo.rb -j /home/ubuntu/hugo-repos/dna.json')
  #     end
  #   end
  # end
  
end
