class AddRootDirToProjects < ActiveRecord::Migration[8.1]
  def change
    # App directory inside a monorepo ("apps/web"); nil means auto-detect.
    add_column :projects, :root_dir, :string
  end
end
