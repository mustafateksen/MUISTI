typealias T = PerceptionEngine.TextLine
func line(_ text: String, _ y: Double = 0.7, _ x: Double = 0.1, _ c: Float = 0.99) -> T {
    T(text:text,box:CGRect(x:x,y:y,width:0.32,height:0.05),confidence:c)
}
func expect(_ name:String, _ lines:[T], _ want:PeanutLabel.Reading?, _ retry:T? = nil) {
    let r = PeanutLabel.evaluate(lines,hash:0,frame:CapturedFrame()) { _ in retry }
    precondition(r?.reading == want, name)
    print("OK",name)
}
expect("list", [line("This product may contain peanuts, milk")], .possible)
expect("compact", [line("CONTAINSALMOND,PEANUTANDSOYINGREDIENTS.")], .contains)
expect("ingredient", [line("Ingredients: Hi-oleic peanuts 99.1%")], .contains)
expect("split", [line("Saattaa sisältää"),line("maapähkinää.",0.64)], .possible)
expect("split negation",[line("May",0.76),line("Contains peanuts")], .inspect)
expect("column mismatch", [line("Saattaa sisältää"),line("maapähkinää.",0.64,0.6)], .inspect)
expect("hazelnut", [line("Hasselpähkinää"),line("Hasselnötter")], nil)
expect("free", [line("Peanut-free")], nil)
expect("conflict", [line("Peanut-free"),line("Contains peanuts",0.5)], .inspect)
expect("nonmatching low confidence", [line("Contains: peanuts",0.7,0.1,0.86)], .inspect,line("Contains milk"))
expect("crop confirms", [line("CONTAINS:PEANUTS,MILK,SOY",0.7,0.1,0.86)], .contains,line("Contains: peanuts, milk, soy"))
expect("isolated", [line("Peanuts")], .inspect)
expect("bare panel", [line("AINESOSAT")], .unreadable)
expect("blank", [], nil)
expect("ingredient block", [line("Ingredients:"),line("Sugar",0.64),line("Peanuts",0.58)], .contains)
expect("block warning", [line("Ingredients:"),line("May contain",0.64),line("Peanuts",0.58)], .possible)
