# frozen_string_literal: true

class ReportRow
  def index
    :row_index
  end
end

class ReportsController < ApplicationController
  def self.index
    :class_level_index
  end

  def index
    @reports = Report.all
  end
end
