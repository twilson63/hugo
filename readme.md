# Hugo docs

=== Methods

    thor hugo:build {customer} {application}

    thor hugo:drop {customer} {application}
    

=== Build Stack

    thor hugo:deploy_rds {customer} {application} # Database Server with {customer} and Database Name as {app}
    
    thor hugo:deploy_elb {customer} # Names the Load Balancer with {customer}
    
    thor hugo:create {customer} [instances] # Call setup_ec2 and register_ec2 per instance
    
      thor hugo:setup_ec2 {instance}
      thor hugo:register_ec2 {customer} {instance}
      
    thor hugo:deploy_ec2 {customer} {app}
    
    
    
== Drop Stack

    thor hugo:terminate_instances {customer}
    thor hugo:delete_elb {customer}
    thor hugo:delete_rds {customer}
    
    
== Info Stack

    thor hugo:list_elb {customer}
    thor hugo:list_rds {customer}