{% begin %}
  PROJECT_ROOT = "{{system("pwd").strip.id}}"
{% end %}
macro spec(file)
  macro load_spec
    \{% path = __DIR__.gsub(%r{\A{{PROJECT_ROOT.id}}}, "").gsub(%r{[^/]+}, "..").id %}
    require "\{{path[1..]}}/spec/{{file.id}}"
  end
  load_spec
end

macro src(file)
  macro load_src
    \{% path = __DIR__.gsub(%r{\A{{PROJECT_ROOT.id}}}, "").gsub(%r{[^/]+}, "..").id %}
    require "\{{path[1..]}}/src/{{file.id}}"
  end
  load_src
end
