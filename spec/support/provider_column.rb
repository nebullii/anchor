# The Platform migration adds projects.provider. Specs for provider-aware
# behaviour include this context so they run (and pass) both before and
# after that migration: if the column is missing it is added for the group
# and dropped afterwards; if it already exists nothing is touched.
RSpec.shared_context "with provider column" do
  before(:all) do
    @added_provider_column = !Project.column_names.include?("provider")
    if @added_provider_column
      ActiveRecord::Base.connection.add_column :projects, :provider, :string, default: "gcp_cloud_run", null: false
      Project.reset_column_information
    end
  end

  after(:all) do
    if @added_provider_column
      ActiveRecord::Base.connection.remove_column :projects, :provider
      Project.reset_column_information
    end
  end
end
