require 'rubygems'
require 'rest-client'
require 'json'
require 'octopi'
require 'ruby-debug'

include Octopi
username = "aoaisfjosdijg"
token = "aoisfjoaijgoaijdgoiadjgioj"

authenticated_with :login => username, :token => token do

  class IssueMigrator
    attr_accessor :redmine_issues
    attr_accessor :github_issues
    attr_accessor :migration_links
    def get_issues
      offset = 0
      issues = []
      begin
        json = RestClient.get("http://bugs.joindiaspora.com/issues", {:params => {:format => :json, :status_id => '*', :limit => 100, :offset => offset}})
        result = JSON.parse(json)
        issues << [*result["issues"]]
        offset = offset + result['limit']
      end while offset < result['total_count']

      puts "Retreived redmine issue index."
      issues.flatten!

      issues.map! do |issue|
        get_comments(issue)
      end
      puts "Retreived comments."

      self.redmine_issues = issues
    end

    def issues
      repo.issues
    end

    def repo
      @repo ||= Repository.find(:name => "redmine-issues-experiment", :user => "diaspora")
    end

    def migrate_issues
      github_issues = []
      issue_pairs = []
      redmine_issues.each do |issue|
        migrate_issue issue
      end
    end

    def migrate_issue issue
      github_issue = create_issue(issue)
      add_labels(github_issue, issue)
      migrate_comments(github_issue, issue)
      github_issue.close! if ["Fixed", "Rejected", "Won't Fix", "Duplicate", "Obsolete"].include? issue["status"]["name"]
      print "."
      github_issues << github_issue
      issue_pairs << [github_issue, issue]
      github_issue
    end

    def create_issue redmine_issue
      params = { :title => redmine_issue["subject"]}
      params[:body] = <<BODY
Issue #{redmine_issue["id"]} from bugs.joindiaspora.com
Created by: **#{redmine_issue["author"]["name"]}**
On #{DateTime.parse(redmine_issue["created_on"]).asctime}

*Priority: #{redmine_issue["priority"]["name"]}*
*Status: #{redmine_issue["status"]["name"]}*
#{
  custom_fields = ''
  redmine_issue["custom_fields"].each do |field|
    custom_fields << "*#{field["name"]}: #{field["value"]}*\n" unless field["value"].nil? || field["value"] == ''
  end if redmine_issue["custom_fields"]
  custom_fields
}

#{redmine_issue["description"]}
BODY
      begin
        Issue.open(:repo => self.repo, :params => params)
      rescue
        redmine_issue["retrying?"] = true
        retry unless redmine_issue["retrying?"]
        puts "Issue open failed for Redmine Issue #{redmine_issue["id"]}"
      end
    end

    def add_labels github_issue, redmine_issue
      labels = []
      if priority = redmine_issue["priority"]
        if priority  == "Low"
          github_issue.add_label(URI.escape("Low Priority"))
        elsif ["High", "Urgent", "Immediate"].include?(priority)
          github_issue.add_label(URI.escape("High Priority"))
        end
      end
      ["tracker", "status", "category"].each do |thing|
        next unless redmine_issue[thing]
        value = redmine_issue[thing]["name"]
        github_issue.add_label URI.escape(value) unless ["New"].include?(value)
      end
    end

    def migrate_comments github_issue, redmine_issue
      redmine_issue["journals"].each do |j|
        next if j["notes"].nil? || j["notes"] == ''
        github_issue.comment <<COMMENT
Comment by: **#{j["user"]["name"]}**
On #{DateTime.parse(j["created_on"]).asctime}

#{j["notes"]}
COMMENT
      end
    end

    def get_comments redmine_issue
      print "."
      issue_json = JSON.parse(RestClient.get("http://bugs.joindiaspora.com/issues/#{redmine_issue["id"]}", :params => {:format => :json, :include => :journals}))
      issue_json["issue"]
    end

    def clear_issues
      puts "Clearing issues!"
      issues.each do |i|
        i.close!
        print '.'
      end
    end
  end

  m = IssueMigrator.new
  m.get_issues

  puts "Migrating issues to github..."
  m.migrate_issues
  puts "Done migrating!"

  ## OPEN
  # http://github.com/api/v2/json/issues/list/diaspora/diaspora/open
  ## CLOSED
  # http://github.com/api/v2/json/issues/list/diaspora/diaspora/closed
end
