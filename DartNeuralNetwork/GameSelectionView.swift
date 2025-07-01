//
//  GameSelectionView.swift
//  DartNeuralNetwork
//
//  Created by Jan Buechele on 24.03.25.
//


import SwiftUI

struct GameSelectionView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Text("Select Game Mode")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top)
                
                NavigationLink(destination: DartsGameLiveView(startingScore: 301)) {
                    Text("301")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal)
                }
                
                NavigationLink(destination: DartsGameLiveView(startingScore: 501)) {
                    Text("501")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .navigationBarTitle("Darts Game Selection", displayMode: .inline)
        }
    }
}

struct GameSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        GameSelectionView()
    }
}
