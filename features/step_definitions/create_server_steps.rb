require 'spec'

When /^I execute command "([^\"]*)"$/ do |cmd|
  @results = exec(cmd)
end

Then /^I should see "([^\"]*)"$/ do |message|
  @results.should == message  
end
