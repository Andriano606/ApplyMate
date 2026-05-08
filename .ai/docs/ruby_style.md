# Ruby Style

## No endless methods

Always use the 3-line form, never the endless (`=`) syntax:

```ruby
# ✗
def form_selector = 'form#apply'

# ✓
def form_selector
  'form#apply'
end
```
