Feature: Create Hugo Server
  In order to setup hugo infrastructures
  As a Ninja
  I want to create a hugo server
  
  Scenario: Create Hugo Server 
    When I execute command "thor hugo:create"
    Then I should see "Successfully created Hugo Server"
    
    
  Scenario: Terminate Hugo Server 
    When I execute command "thor hugo:terminate"
    Then I should see "Successfully stopped Hugo Server"    