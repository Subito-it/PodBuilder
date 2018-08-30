class String
  def detect_indentation
    return self[/\A\s*/]
  end
end
