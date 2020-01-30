require 'fastlane_core'
require 'pty'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'terminal-table'
require 'xcov-core'
require 'pathname'
require 'json'
require 'xcresult'
require 'digest'

module Xcov
  class Manager

    def initialize(options)
      # Set command options
      Xcov.config = options

      # Set project options
      FastlaneCore::Project.detect_projects(options)
      Xcov.project = FastlaneCore::Project.new(options)

      # Set ignored files handler
      Xcov.ignore_handler = IgnoreHandler.new

      # Print summary
      FastlaneCore::PrintTable.print_values(config: options, hide_keys: [:slack_url, :coveralls_repo_token], title: "Summary for xcov #{Xcov::VERSION}")
    end

    def run
      # Run xcov
      json_report = parse_xccoverage
      report = generate_xcov_report(json_report)
      validate_report(report)
      submit_to_coveralls(report)
      tmp_dir = File.join(Xcov.config[:output_directory], 'tmp')
      FileUtils.rm_rf(tmp_dir) if File.directory?(tmp_dir)
    end

    def parse_xccoverage
      xccoverage_files = []

      # xcresults to parse and export after collecting
      xcresults_to_parse_and_export = []

      # Find .xccoverage file
      # If no xccov direct path, use the old derived data path method
      if xccov_file_direct_paths.nil?
        extension = Xcov.config[:legacy_support] ? "xccoverage" : "xccovreport"
        test_logs_path = derived_data_path + "Logs/Test/"
        xccoverage_files = Dir["#{test_logs_path}*.#{extension}", "#{test_logs_path}*.xcresult/*/action.#{extension}"].sort_by { |filename| File.mtime(filename) }.reverse

        if xccoverage_files.empty?
          xcresult_paths = Dir["#{test_logs_path}*.xcresult"].sort_by { |filename| File.mtime(filename) }.reverse
          xcresult_paths.each do |xcresult_path|
            xcresults_to_parse_and_export << xcresult_path
          end
        end

        unless test_logs_path.directory?
          ErrorHandler.handle_error("XccoverageFileNotFound")
        end
      else
        # Iterate over direct paths and find .xcresult files
        # that need to be processed before getting coverage
        xccov_file_direct_paths.each do |path|
          if File.extname(path) == '.xcresult'
            xcresults_to_parse_and_export << path
          else
            xccoverage_files << path
          end
        end
      end

      # Iterates over xcresults
      # Exports .xccovarchives
      # Exports .xccovreports and collects the paths
      unless xcresults_to_parse_and_export.empty?
        xccoverage_files = process_xcresults!(xcresults_to_parse_and_export)
      end

      # Errors if no coverage files were found
      if xccoverage_files.empty?
        ErrorHandler.handle_error("XccoverageFileNotFound")
      end

      # Convert .xccoverage file to json
      ide_foundation_path = Xcov.config[:legacy_support] ? nil : Xcov.config[:ideFoundationPath]
      json_report = Xcov::Core::Parser.parse(xccoverage_files.first, Xcov.config[:output_directory], ide_foundation_path)

      # This assumes only 1 xcresult file, can make more robust after finding proper place for this
      tmp_dir = File.join(Xcov.config[:output_directory], 'tmp_lines')
      FileUtils.mkdir(tmp_dir) unless File.directory?(tmp_dir)

      jobs = [] # Array of { tempfile: , pid:}
      json_report["targets"].each.with_index do |target, target_index|
        target["files"].each.with_index do |file, file_index|
          filepath = file['location']
          filepath_hash = Digest::SHA2.hexdigest(filepath)
          lines_output_path = File.join(tmp_dir, filepath_hash)

          job_pid = fork do
            `xcrun xccov view --archive --file "#{file['location']}" #{xcresults_to_parse_and_export.first} > #{lines_output_path}`
          end

          jobs << {
            pid: job_pid,
            filepath: filepath,
            lines_output_path: lines_output_path,
            # maybe have a path into json_report to not have to iterate it later
            json_report_target_index: target_index,
            json_report_file_index: file_index
          }

          if file_index % 10 == 0
            sleep(1)
          end
        end
      end

      puts "JOB COUNT: #{jobs.count}"

      # process all the jobs
      jobs.each do |job|
        Process.wait(job[:pid])
        # puts "Job: #{job[:pid]} file: #{job[:filepath]}"

        lines = []
        File.readlines(job[:lines_output_path]).each do |line|
          # This matches [Number]: [Number or *]
          # First grouping is the entire match
          # Second grouping is line number
          # Third grouping is execution count (* means non-executable)
          matches = line.match(/(\d+): ([*0-9]+)/)
          if matches.nil?
            # skip lines that look like (1, 2, 3)
            next
          end
          lines << {
            "executionCount" => matches[2].to_i, # Int
            "executable" => matches[2] != "*",
            "ranges" => nil
          }
        end
        json_report["targets"][job[:json_report_target_index]]["files"][job[:json_report_file_index]]["lines"] = lines
      end
      # cleanup tempfiles
      FileUtils.rm_rf(tmp_dir) if File.directory?(tmp_dir)

      ErrorHandler.handle_error("UnableToParseXccoverageFile") if json_report.nil?

      json_report
    end

    private

    def generate_xcov_report(json_report)
      # Create output path
      output_path = Xcov.config[:output_directory]
      FileUtils.mkdir_p(output_path)

      # Convert report to xcov model objects
      report = Report.map(json_report)

      # Raise exception in case of failure
      ErrorHandler.handle_error("UnableToMapJsonToXcovModel") if report.nil?

      if Xcov.config[:html_report] then
        resources_path = File.join(output_path, "resources")
        FileUtils.mkdir_p(resources_path)

        # Copy images to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/images/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Copy stylesheets to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/stylesheets/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Copy javascripts to output resources folder
        Dir[File.join(File.dirname(__FILE__), "../../assets/javascripts/*")].each do |path|
          FileUtils.cp_r(path, resources_path)
        end

        # Create HTML report
        File.open(File.join(output_path, "index.html"), "wb") do |file|
          file.puts report.html_value
        end
      end

      # Create Markdown report
      if Xcov.config[:markdown_report] then
        File.open(File.join(output_path, "report.md"), "wb") do |file|
          file.puts report.markdown_value
        end
      end

      # Create JSON report
      if Xcov.config[:json_report] then
        File.open(File.join(output_path, "report.json"), "wb") do |file|
          file.puts report.json_value.to_json
        end
      end

      # Post result
      SlackPoster.new.run(report)

      # Print output
      table_rows = []
      report.targets.each do |target|
        table_rows << [target.name, target.displayable_coverage]
      end
      puts Terminal::Table.new({
        title: "xcov Coverage Report".green,
        rows: table_rows
      })
      puts ""

      report
    end

    def validate_report(report)
      # Raise exception if overall coverage is under threshold
      minimumPercentage = Xcov.config[:minimum_coverage_percentage] / 100
      if minimumPercentage > report.coverage
        error_message = "Actual Code Coverage (#{"%.2f%%" % (report.coverage*100)}) below threshold of #{"%.2f%%" % (minimumPercentage*100)}"
        ErrorHandler.handle_error_with_custom_message("CoverageUnderThreshold", error_message)
      end
    end

    def submit_to_coveralls(report)
      if Xcov.config[:disable_coveralls]
        return
      end
      if !Xcov.config[:coveralls_repo_token].nil? || !(Xcov.config[:coveralls_service_name].nil? && Xcov.config[:coveralls_service_job_id].nil?)
        CoverallsHandler.submit(report)
      end
    end

    # Auxiliar methods
    def derived_data_path
      # If DerivedData path was supplied, return
      return Pathname.new(Xcov.config[:derived_data_path]) unless Xcov.config[:derived_data_path].nil?

      # Otherwise check project file
      product_builds_path = Pathname.new(Xcov.project.default_build_settings(key: "SYMROOT"))
      return product_builds_path.parent.parent
    end

    def xccov_file_direct_paths
      # If xccov_file_direct_path was supplied, return
      if Xcov.config[:xccov_file_direct_path].nil?
          return nil
      end

      path = Xcov.config[:xccov_file_direct_path]
      return [Pathname.new(path).to_s]
    end

    def process_xcresults!(xcresult_paths)
      output_path = Xcov.config[:output_directory]
      FileUtils.mkdir_p(output_path)

      return xcresult_paths.flat_map do |xcresult_path|
        begin
          parser = XCResult::Parser.new(path: xcresult_path)

          # Exporting to same directory as xcresult
          archive_paths = parser.export_xccovarchives(destination: output_path)
          report_paths = parser.export_xccovreports(destination: output_path)

          # Informating user of export paths
          archive_paths.each do |path|
            UI.important("Copying .xccovarchive to #{path}") 
          end
          report_paths.each do |path|
            UI.important("Copying .xccovreport to #{path}") 
          end

          report_paths
        rescue
          UI.error("Error occured while exporting xccovreport from xcresult '#{xcresult_path}'")
          UI.error("Make sure you have both Xcode 11 selected and pointing to the correct xcresult file")
          UI.crash!("Failed to export xccovreport from xcresult'")
        end
      end
    end
  end
end
