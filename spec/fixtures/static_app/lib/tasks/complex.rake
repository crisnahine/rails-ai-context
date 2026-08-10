namespace :deploy do
  desc "Deploy to staging"
  task :staging do
    puts "Deploying to staging"
  end

  namespace :db do
    desc "Migrate staging database"
    task :migrate do
      puts "Migrating"
    end

    task :seed do
      puts "Seeding (no description)"
    end
  end
end

desc "Top-level task"
task :ping do
  puts "pong"
end
